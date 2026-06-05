# app.R
# Student Rotation Scheduler Shiny App
#
# Run with:
# install.packages(c(
#   "shiny", "ompr", "ompr.roi", "ROI.plugin.glpk",
#   "dplyr", "tidyr", "DT"
# ))
#
# shiny::runApp("app.R")

library(ompr)
library(ompr.roi)
library(ROI.plugin.glpk)
library(dplyr)
library(tidyr)

# -----------------------------
# Helper functions
# -----------------------------

parse_list_input <- function(x) {
  x <- gsub("[;\n\r]+", ",", x)
  out <- trimws(unlist(strsplit(x, ",")))
  out <- out[nzchar(out)]
  unique(out)
}

make_days <- function(n_weeks, days_per_week) {
  paste0("Day ", seq_len(n_weeks * days_per_week))
}

make_rotation_dates <- function(start_date, n_days) {
  # Returns the first n_days weekdays beginning on/after start_date.
  # Weekends are skipped.
  start_date <- as.Date(start_date)

  candidate_dates <- seq.Date(
    from = start_date,
    by = "day",
    length.out = n_days + ceiling(n_days / 5) * 4 + 14
  )

  weekday_dates <- candidate_dates[weekdays(candidate_dates) %in% c(
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday"
  )]

  weekday_dates[seq_len(n_days)]
}

format_schedule_date <- function(x) {
  x <- as.Date(x)
  paste0(
    weekdays(x), ", ",
    format(x, "%B"), " ",
    as.integer(format(x, "%d"))
  )
}

normalize_locations <- function(locations, services) {
  # locations should look like:
  # service,Monday,Tuesday,Wednesday,Thursday,Friday
  # GI,Main Campus,Main Campus,East Campus,East Campus,Main Campus
  #
  # If there is no column named service, the first column is treated as service.

  if (is.null(locations)) {
    locations <- data.frame(service = services, stringsAsFactors = FALSE)
  }

  locations <- as.data.frame(locations, stringsAsFactors = FALSE)

  if (!"service" %in% names(locations)) {
    names(locations)[1] <- "service"
  }

  required_days <- c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")

  for (day_name in required_days) {
    if (!day_name %in% names(locations)) {
      locations[[day_name]] <- NA_character_
    }
  }

  locations %>%
    mutate(service = as.character(service)) %>%
    select(service, all_of(required_days)) %>%
    pivot_longer(
      cols = all_of(required_days),
      names_to = "weekday",
      values_to = "location"
    ) %>%
    mutate(
      location = trimws(as.character(location)),
      location = ifelse(is.na(location) | location == "", NA_character_, location)
    )
}

is_academic_location <- function(x) {
  !is.na(x) & tolower(trimws(as.character(x))) == "academic"
}

make_academic_location_matrix <- function(days, services, start_date = NULL, locations = NULL) {
  # Returns a day x service matrix where 1 means the service-day location is "academic".
  # These assignments are allowed, but heavily penalized in the optimizer.

  n_days <- length(days)
  n_services <- length(services)

  academic_location <- matrix(0, nrow = n_days, ncol = n_services)

  if (is.null(start_date) || is.null(locations)) {
    return(academic_location)
  }

  rotation_dates <- make_rotation_dates(start_date = start_date, n_days = n_days)

  day_lookup <- tibble(
    day_id = seq_along(days),
    weekday = weekdays(rotation_dates)
  )

  location_long <- normalize_locations(locations = locations, services = services)

  academic_df <- expand.grid(
    day_id = seq_along(days),
    service_id = seq_along(services),
    stringsAsFactors = FALSE
  ) %>%
    mutate(
      service = services[service_id]
    ) %>%
    left_join(day_lookup, by = "day_id") %>%
    left_join(location_long, by = c("service", "weekday")) %>%
    mutate(is_academic = is_academic_location(location))

  academic_location[cbind(academic_df$day_id, academic_df$service_id)] <- as.integer(academic_df$is_academic)

  academic_location
}

add_schedule_metadata <- function(assignments, days, start_date = NULL, locations = NULL, days_per_week = 5) {
  n_days <- length(days)

  if (is.null(start_date)) {
    day_lookup <- tibble(
      day = days,
      day_num = seq_along(days),
      week = ceiling(seq_along(days) / days_per_week),
      date = as.Date(NA),
      weekday = NA_character_,
      date_label = days
    )
  } else {
    rotation_dates <- make_rotation_dates(start_date = start_date, n_days = n_days)

    day_lookup <- tibble(
      day = days,
      day_num = seq_along(days),
      week = ceiling(seq_along(days) / days_per_week),
      date = rotation_dates,
      weekday = weekdays(rotation_dates),
      date_label = format_schedule_date(rotation_dates)
    )
  }

  out <- assignments %>%
    left_join(day_lookup, by = "day")

  if (!is.null(locations)) {
    location_long <- normalize_locations(locations = locations, services = unique(assignments$service))

    out <- out %>%
      left_join(location_long, by = c("service", "weekday"))
  } else {
    out <- out %>%
      mutate(location = NA_character_)
  }

  out %>%
    mutate(
      is_academic_location = is_academic_location(location),
      assignment = ifelse(
        is.na(location) | location == "",
        service,
        paste0(service, " - ", location)
      )
    )
}

make_availability <- function(days, services, n_weeks, days_per_week, input) {
  availability <- expand.grid(
    day = days,
    service = services,
    stringsAsFactors = FALSE
  ) %>%
    mutate(
      day_num = as.integer(gsub("[^0-9]", "", day)),
      week = ceiling(day_num / days_per_week)
    )

  availability$available <- FALSE

  for (w in seq_len(n_weeks)) {
    selected <- input[[paste0("week_services_", w)]]

    if (is.null(selected)) {
      selected <- character(0)
    }

    availability$available[availability$week == w & availability$service %in% selected] <- TRUE
  }

  availability %>%
    select(day, service, available)
}

read_locations_file <- function(file_info, default_path = "locations.csv") {
  # Use an uploaded locations.csv if provided. Otherwise, fall back to a
  # bundled locations.csv stored in the same directory as app.R.
  if (!is.null(file_info)) {
    return(read.csv(file_info$datapath, stringsAsFactors = FALSE, check.names = FALSE))
  }

  if (file.exists(default_path)) {
    return(read.csv(default_path, stringsAsFactors = FALSE, check.names = FALSE))
  }

  NULL
}

# -----------------------------
# Scheduler function
# -----------------------------

schedule_rotation <- function(
    students,
    services,
    days,
    availability,
    start_date = NULL,
    locations = NULL,
    days_per_week = 5,
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

  academic_location <- make_academic_location_matrix(
    days = days,
    services = services,
    start_date = start_date,
    locations = locations
  )

  # Treat service-days with location == "Academic" as truly unavailable.
  # These assignments are forbidden, not merely penalized.
  available[academic_location == 1] <- 0

  available_per_day <- rowSums(available)

  # If there are fewer available services than students on a given day,
  # allow multiple students to share available services on that day.
  # When there are enough services, preserve the usual one-student-per-service rule.
  if (any(available_per_day == 0)) {
    bad_days <- days[which(available_per_day == 0)]
    stop(
      "Infeasible: no available services on these days after applying availability and academic-location exclusions: ",
      paste(bad_days, collapse = ", ")
    )
  }

  service_capacity_by_day <- ifelse(
    available_per_day < n_students,
    ceiling(n_students / available_per_day),
    1
  )

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

  # Maximum number of student-slots each service can support over the rotation.
  # This accounts for days where multiple students are allowed on a service because
  # the number of students exceeds the number of available services.
  service_available_slots <- colSums(
    available * matrix(
      service_capacity_by_day,
      nrow = n_days,
      ncol = n_services,
      byrow = FALSE
    )
  )

  if (require_all_available) {
    too_rare <- services_available_at_least_once[
      service_available_slots[services_available_at_least_once] <
        n_students * min_exposures_per_student
    ]

    if (length(too_rare) > 0) {
      stop(
        "Infeasible: these services do not have enough available student-slots for every student to see them ",
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

    # Each service usually gets at most one student per day.
    # If a day has fewer available services than students, allow multiple students
    # on available services for that day, up to service_capacity_by_day[d].
    add_constraint(
      sum_expr(x[s, d, v], s = student_ids) <= service_capacity_by_day[d],
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

  long_schedule <- add_schedule_metadata(
    assignments = assignments,
    days = days,
    start_date = start_date,
    locations = locations,
    days_per_week = days_per_week
  ) %>%
    arrange(day_num, student) %>%
    select(week, date_label, date, weekday, day_num, day, student, service, location, is_academic_location, assignment)

  wide_schedule <- long_schedule %>%
    mutate(date_label = factor(date_label, levels = unique(date_label), ordered = TRUE)) %>%
    select(week, date_label, student, assignment) %>%
    pivot_wider(
      names_from = student,
      values_from = assignment
    ) %>%
    arrange(date_label) %>%
    mutate(date_label = as.character(date_label)) %>%
    rename(date = date_label)

  list(
    long = long_schedule,
    wide = wide_schedule
  )
}

# ----------------- EXAMPLE CODE -----------------
# Example usage:
#
# students <- c("Student A", "Student B", "Student C")
#
# services <- c(
#   "GU",
#   "Breast",
#   "GI",
#   "H&N",
#   "CNS/Peds",
#   "Gyn/Peds/Lymph",
#   "Thoracic/Sarc/Lymph"
# )
#
# days <- paste0("Day ", 1:10)
# start_date <- as.Date("2026-07-06")
#
# availability <- expand.grid(
#   day = days,
#   service = services,
#   stringsAsFactors = FALSE
# ) %>%
#   mutate(
#     week = ifelse(day %in% paste0("Day ", 1:5), 1, 2),
#     available = case_when(
#       week == 1 & service %in% c("Breast", "GI", "H&N", "CNS/Peds", "Gyn/Peds/Lymph") ~ TRUE,
#       week == 2 & service %in% c("GU", "Breast", "GI", "H&N", "Thoracic/Sarc/Lymph") ~ TRUE,
#       TRUE ~ FALSE
#     )
#   ) %>%
#   select(day, service, available)
#
# locations <- read.csv("locations.csv", stringsAsFactors = FALSE, check.names = FALSE)
#
# sched <- schedule_rotation(
#   students = students,
#   services = services,
#   days = days,
#   availability = availability,
#   start_date = start_date,
#   locations = locations,
#   days_per_week = 5,
#   require_all_available = TRUE,
#   min_exposures_per_student = 1
# )
#
# sched$wide
# sched$long
# sched$long %>% filter(is_academic_location)
