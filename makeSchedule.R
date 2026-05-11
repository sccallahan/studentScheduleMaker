# install.packages(c("ompr", "ompr.roi", "ROI.plugin.glpk", "dplyr", "tidyr"))

library(ompr)
library(ompr.roi)
library(ROI.plugin.glpk)
library(dplyr)
library(tidyr)

schedule_rotation <- function(
    students,
    services,
    days,
    availability,
    require_all_available = TRUE,
    min_exposures_per_student = 1,
    back_to_back_penalty = 100,
    imbalance_penalty = 1
) {
  n_students <- length(students)
  n_services <- length(services)
  n_days <- length(days)
  
  student_ids <- seq_along(students)
  service_ids <- seq_along(services)
  day_ids <- seq_along(days)
  
  avail_mat <- availability %>%
    mutate(
      day_id = match(day, days),
      service_id = match(service, services)
    ) %>%
    select(day_id, service_id, available) %>%
    complete(
      day_id = day_ids,
      service_id = service_ids,
      fill = list(available = FALSE)
    ) %>%
    arrange(day_id, service_id)
  
  available <- matrix(
    avail_mat$available,
    nrow = n_days,
    ncol = n_services,
    byrow = TRUE
  )
  
  available_per_day <- rowSums(available)
  
  if (any(available_per_day < n_students)) {
    bad_days <- days[which(available_per_day < n_students)]
    stop(
      "Infeasible: fewer available services than students on these days: ",
      paste(bad_days, collapse = ", ")
    )
  }
  
  services_available_at_least_once <- service_ids[colSums(available) > 0]
  
  if (
    require_all_available &&
    length(services_available_at_least_once) * min_exposures_per_student > n_days
  ) {
    stop(
      "Infeasible: each student cannot see ",
      length(services_available_at_least_once),
      " services ",
      min_exposures_per_student,
      " time(s) each in only ",
      n_days,
      " days."
    )
  }
  
  service_available_days <- colSums(available)
  
  if (require_all_available) {
    too_rare <- services_available_at_least_once[
      service_available_days[services_available_at_least_once] <
        n_students * min_exposures_per_student
    ]
    
    if (length(too_rare) > 0) {
      stop(
        "Infeasible: these services are not available on enough days for every student to see them ",
        min_exposures_per_student,
        " time(s): ",
        paste(services[too_rare], collapse = ", ")
      )
    }
  }
  
  target_per_service <- ceiling(
    n_days / max(1, length(services_available_at_least_once))
  )
  
  model <- MIPModel() %>%
    add_variable(x[s, d, v], s = student_ids, d = day_ids, v = service_ids, type = "binary") %>%
    add_variable(y[s, d, v], s = student_ids, d = day_ids[-1], v = service_ids, type = "binary") %>%
    add_variable(excess[s, v], s = student_ids, v = service_ids, type = "integer", lb = 0) %>%
    
    # Each student gets exactly one service per day
    add_constraint(
      sum_expr(x[s, d, v], v = service_ids) == 1,
      s = student_ids,
      d = day_ids
    ) %>%
    
    # Each service gets at most one student per day
    add_constraint(
      sum_expr(x[s, d, v], s = student_ids) <= 1,
      d = day_ids,
      v = service_ids
    ) %>%
    
    # Cannot assign unavailable services
    add_constraint(
      x[s, d, v] <= available[d, v],
      s = student_ids,
      d = day_ids,
      v = service_ids
    ) %>%
    
    # Detect back-to-back repeats
    add_constraint(
      y[s, d, v] >= x[s, d, v] + x[s, d - 1, v] - 1,
      s = student_ids,
      d = day_ids[-1],
      v = service_ids
    ) %>%
    
    # Penalize excessive repetition of one service
    add_constraint(
      excess[s, v] >= sum_expr(x[s, d, v], d = day_ids) - target_per_service,
      s = student_ids,
      v = service_ids
    )
  
  # Require each student to see each available service at least once
  if (require_all_available) {
    for (v in services_available_at_least_once) {
      model <- model %>%
        add_constraint(
          sum_expr(x[s, d, v], d = day_ids) >= min_exposures_per_student,
          s = student_ids
        )
    }
  }
  
  model <- model %>%
    set_objective(
      back_to_back_penalty *
        sum_expr(y[s, d, v], s = student_ids, d = day_ids[-1], v = service_ids) +
        imbalance_penalty *
        sum_expr(excess[s, v], s = student_ids, v = service_ids),
      sense = "min"
    )
  
  result <- solve_model(model, with_ROI(solver = "glpk"))
  
  status <- solver_status(result)
  if (status != "success") {
    stop("No feasible schedule found. Solver status: ", status)
  }
  
  assignments <- get_solution(result, x[s, d, v]) %>%
    filter(value > 0.5) %>%
    mutate(
      student = students[s],
      day = days[d],
      service = services[v]
    ) %>%
    arrange(d, s) %>%
    select(day, student, service)
  
  wide_schedule <- assignments %>%
    mutate(day = factor(day, levels = days, ordered = TRUE)) %>%
    pivot_wider(
      names_from = student,
      values_from = service
    ) %>%
    arrange(day) %>%
    mutate(day = as.character(day))
  
  list(
    long = assignments,
    wide = wide_schedule
  )
}


# ----------------- EXAMPLE CODE -----------------
## 2 Weekers ----
# students <- c("Student A", "Student B", "Student C")
# 
# services <- c(
#   "Breast",
#   "GI",
#   "GU",
#   "Thoracic",
#   "CNS",
#   "Peds",
#   "Gyn"
# )
# 
# days <- paste0("Day ", 1:10)
# 
# # Example: two-week rotation with weekday-style days
# # Here services differ by week.
# availability <- expand.grid(
#   day = days,
#   service = services,
#   stringsAsFactors = FALSE
# ) %>%
#   mutate(
#     week = ifelse(day %in% paste0("Day ", 1:5), 1, 2),
#     available = case_when(
#       week == 1 & service %in% c("Breast", "GI", "GU", "Thoracic", "CNS") ~ TRUE,
#       week == 2 & service %in% c("GI", "GU", "Thoracic", "Peds", "Gyn") ~ TRUE,
#       TRUE ~ FALSE
#     )
#   ) %>%
#   select(day, service, available)
# 
# set.seed(1)
# 
# sched <- schedule_rotation(
#   students = students,
#   services = services,
#   days = days,
#   availability = availability
# )
# 
# sched$wide

## 4 Weekers ----
# days <- paste0("Day ", 1:20)
# 
# availability <- expand.grid(
#   day = days,
#   service = services,
#   stringsAsFactors = FALSE
# ) %>%
#   mutate(
#     day_num = as.integer(gsub("Day ", "", day)),
#     week = ceiling(day_num / 5),
#     available = case_when(
#       week == 1 & service %in% c("Breast", "GI", "GU", "Thoracic") ~ TRUE,
#       week == 2 & service %in% c("GI", "GU", "CNS", "Peds", "Gyn") ~ TRUE,
#       week == 3 & service %in% c("Breast", "Thoracic", "CNS", "Peds") ~ TRUE,
#       week == 4 & service %in% c("Breast", "GI", "GU", "Gyn") ~ TRUE,
#       TRUE ~ FALSE
#     )
#   ) %>%
#   select(day, service, available)
# 
# set.seed(1)
# 
# sched <- schedule_rotation(
#   students = students,
#   services = services,
#   days = days,
#   availability = availability
# )
# 
# sched$wide
