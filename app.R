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

library(shiny)
library(ompr)
library(ompr.roi)
library(ROI.plugin.glpk)
library(dplyr)
library(tidyr)
library(DT)
library(ggplot2)

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


default_service_colors <- c(
  "GU" = "#b6d7a8",
  "Breast" = "#f9cb9c",
  "GI" = "#b4a7d6",
  "H&N" = "#a4c2f4",
  "CNS/Peds" = "#d9d9d9",
  "Gyn/Peds/Lymph" = "#d5a6bd",
  "Thoracic/Sarc/Lymph" = "#ffe599"
)

get_service_colors <- function(services) {
  service_colors <- default_service_colors
  extra_services <- setdiff(services, names(service_colors))

  if (length(extra_services) > 0) {
    extra_colors <- grDevices::hcl.colors(length(extra_services), palette = "Set 2")
    names(extra_colors) <- extra_services
    service_colors <- c(service_colors, extra_colors)
  }

  service_colors[services]
}

make_schedule_plot <- function(long_schedule, service_colors = NULL) {
  if (is.null(service_colors)) {
    service_colors <- get_service_colors(unique(long_schedule$service))
  }

  plot_data <- long_schedule %>%
    mutate(
      student = factor(student, levels = unique(student)),
      date_plot = factor(date_label, levels = rev(unique(date_label)), ordered = TRUE),
      tile_label = ifelse(
        is.na(location) | location == "",
        service,
        paste0(service, "\n", location)
      )
    )

  ggplot(plot_data, aes(x = student, y = date_plot, fill = service)) +
    geom_tile(color = "white", linewidth = 0.8) +
    geom_text(aes(label = tile_label), size = 3.1, lineheight = 0.95) +
    scale_fill_manual(values = service_colors, drop = FALSE) +
    labs(x = "Student", y = NULL, fill = "Service") +
    theme_minimal(base_size = 12) +
    theme(
      panel.grid = element_blank(),
      axis.text.x = element_text(face = "bold"),
      axis.text.y = element_text(size = 10),
      legend.position = "bottom"
    )
}


read_manual_wide_schedule_file <- function(file_info) {
  if (is.null(file_info)) {
    return(NULL)
  }

  read.csv(file_info$datapath, stringsAsFactors = FALSE, check.names = FALSE)
}

wide_schedule_to_long_for_plot <- function(wide_schedule, days_per_week = 5) {
  # Converts an edited "wide" schedule CSV back into long format for plotting.
  #
  # Expected wide format:
  #   week,date,Student A,Student B,Student C
  #   1,"Monday, January 1","GI - Main Campus","GU - East Campus","Breast"
  #
  # Student cells can contain either:
  #   Service
  # or:
  #   Service - Location

  wide_schedule <- as.data.frame(
    wide_schedule,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )

  if (nrow(wide_schedule) == 0 || ncol(wide_schedule) < 2) {
    stop("The uploaded wide schedule must have at least one date column and one student column.")
  }

  nms <- names(wide_schedule)

  date_col <- if ("date" %in% nms) {
    "date"
  } else if ("date_label" %in% nms) {
    "date_label"
  } else {
    nms[1]
  }

  week_col <- if ("week" %in% nms) "week" else NA_character_

  exclude_cols <- unique(c(
    date_col,
    "week",
    "date",
    "date_label",
    "weekday",
    "day",
    "day_num"
  ))

  student_cols <- setdiff(nms, exclude_cols)

  if (length(student_cols) == 0) {
    stop("Could not identify student columns in the uploaded wide schedule.")
  }

  if (!is.na(week_col)) {
    row_lookup <- wide_schedule %>%
      mutate(
        .row_id = row_number(),
        date_label = as.character(.data[[date_col]]),
        week = .data[[week_col]]
      ) %>%
      select(.row_id, week, date_label)
  } else {
    row_lookup <- wide_schedule %>%
      mutate(
        .row_id = row_number(),
        date_label = as.character(.data[[date_col]]),
        week = ceiling(row_number() / days_per_week)
      ) %>%
      select(.row_id, week, date_label)
  }

  wide_schedule %>%
    mutate(.row_id = row_number()) %>%
    select(.row_id, all_of(student_cols)) %>%
    pivot_longer(
      cols = all_of(student_cols),
      names_to = "student",
      values_to = "assignment"
    ) %>%
    left_join(row_lookup, by = ".row_id") %>%
    mutate(
      assignment = trimws(as.character(assignment)),
      assignment = ifelse(is.na(assignment) | assignment == "", NA_character_, assignment)
    ) %>%
    filter(!is.na(assignment)) %>%
    mutate(
      service = trimws(sub("\\s+-\\s+.*$", "", assignment)),
      location = ifelse(
        grepl("\\s+-\\s+", assignment),
        trimws(sub("^.*?\\s+-\\s+", "", assignment)),
        NA_character_
      ),
      date = as.Date(NA),
      weekday = ifelse(grepl(",", date_label), sub(",.*$", "", date_label), NA_character_),
      day_num = .row_id,
      day = paste0("Manual Day ", .row_id),
      is_academic_location = is_academic_location(location)
    ) %>%
    select(
      week,
      date_label,
      date,
      weekday,
      day_num,
      day,
      student,
      service,
      location,
      is_academic_location,
      assignment
    ) %>%
    arrange(day_num, student)
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
    service_emphasis = NULL,
    emphasis_per_week = 2,
    allow_emphasis_back_to_back = TRUE,
    emphasis_shortfall_penalty = 10000,
    coverage_shortfall_penalty = 50,
    back_to_back_penalty = 100,
    imbalance_penalty = 1
) {
  n_students <- length(students)
  n_services <- length(services)
  n_days <- length(days)

  student_ids <- seq_along(students)
  service_ids <- seq_along(services)
  day_ids <- seq_along(days)

  # Normalize optional student-specific service emphasis.
  # service_emphasis should be a data frame with columns:
  #   student, service
  # Optional column:
  #   target_per_week
  # If target_per_week is absent, emphasis_per_week is used.
  #
  # Emphasis targets are finalized after the availability matrix is built,
  # because targets should only apply in weeks where the emphasized service is
  # actually available after academic-location exclusions.
  if (!is.null(service_emphasis) && nrow(as.data.frame(service_emphasis)) > 0) {
    service_emphasis <- as.data.frame(service_emphasis, stringsAsFactors = FALSE)

    if (!all(c("student", "service") %in% names(service_emphasis))) {
      stop("service_emphasis must have columns named 'student' and 'service'.")
    }

    if (!"target_per_week" %in% names(service_emphasis)) {
      service_emphasis$target_per_week <- emphasis_per_week
    }

    service_emphasis <- service_emphasis %>%
      mutate(
        student = trimws(as.character(student)),
        service = trimws(as.character(service)),
        target_per_week = as.numeric(target_per_week)
      ) %>%
      filter(
        student %in% students,
        service %in% services,
        !is.na(target_per_week),
        target_per_week > 0
      )
  } else {
    service_emphasis <- data.frame(
      student = character(0),
      service = character(0),
      target_per_week = numeric(0),
      stringsAsFactors = FALSE
    )
  }

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

  # Build emphasis targets after applying availability and academic exclusions.
  # Targets are weekly: if a student emphasizes GI with target_per_week = 2,
  # the optimizer strongly tries to schedule GI twice in each week where GI is
  # available. If the emphasized service is unavailable for a week, that week
  # contributes no emphasis target.
  n_rotation_weeks <- ceiling(n_days / days_per_week)
  week_ids <- ceiling(day_ids / days_per_week)

  emphasis_target <- matrix(0, nrow = n_students, ncol = n_services)
  emphasis_week_target <- array(0, dim = c(n_students, n_rotation_weeks, n_services))

  if (nrow(service_emphasis) > 0) {
    for (i in seq_len(nrow(service_emphasis))) {
      s_id <- match(service_emphasis$student[i], students)
      v_id <- match(service_emphasis$service[i], services)
      target_per_week_i <- service_emphasis$target_per_week[i]

      for (w in seq_len(n_rotation_weeks)) {
        week_day_ids <- day_ids[week_ids == w]
        available_days_this_week <- sum(available[week_day_ids, v_id] > 0)

        # A single student can only be on one service per day, so the weekly
        # target cannot exceed the number of days that service is available.
        weekly_target <- ifelse(
          available_days_this_week > 0,
          min(target_per_week_i, available_days_this_week),
          0
        )

        emphasis_week_target[s_id, w, v_id] <- weekly_target
      }
    }

    emphasis_target <- apply(emphasis_week_target, c(1, 3), sum)
  }

  has_emphasis <- rowSums(emphasis_target) > 0
  coverage_relaxed <- matrix(
    as.integer(has_emphasis & require_all_available),
    nrow = n_students,
    ncol = n_services,
    byrow = FALSE
  )
  emphasis_active <- matrix(
    as.integer(emphasis_target > 0),
    nrow = n_students,
    ncol = n_services
  )
  emphasis_week_active <- array(
    as.integer(emphasis_week_target > 0),
    dim = c(n_students, n_rotation_weeks, n_services)
  )

  # Back-to-back repeats are usually penalized. If requested, remove that
  # penalty for each student's emphasized service so consecutive emphasis
  # days are allowed when helpful.
  back_to_back_weight <- matrix(1, nrow = n_students, ncol = n_services)
  if (isTRUE(allow_emphasis_back_to_back)) {
    back_to_back_weight[emphasis_active == 1] <- 0
  }

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

  # If a student has an emphasis service, their all-service exposure requirement
  # is softened so they can miss another service in order to emphasize the chosen one.
  # Students without an emphasis still have the usual hard exposure requirement.
  hard_exposure_students <- student_ids[!has_emphasis]

  if (
    require_all_available &&
    length(hard_exposure_students) > 0 &&
    length(services_available_at_least_once) * min_exposures_per_student > n_days
  ) {
    stop(
      "Infeasible: non-emphasis students cannot see ",
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

  if (require_all_available && length(hard_exposure_students) > 0) {
    too_rare <- services_available_at_least_once[
      service_available_slots[services_available_at_least_once] <
        length(hard_exposure_students) * min_exposures_per_student
    ]

    if (length(too_rare) > 0) {
      stop(
        "Infeasible: these services do not have enough available student-slots for every non-emphasis student to see them ",
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
    add_variable(coverage_shortfall[s, v], s = student_ids, v = service_ids, type = "integer", lb = 0) %>%
    add_variable(emphasis_shortfall[s, v], s = student_ids, v = service_ids, type = "integer", lb = 0) %>%
    add_variable(emphasis_week_shortfall[s, w, v], s = student_ids, w = seq_len(n_rotation_weeks), v = service_ids, type = "integer", lb = 0) %>%

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
    ) %>%

    # For emphasis students, missed all-service exposure requirements are allowed
    # but penalized. For non-emphasis students, hard constraints are added below.
    add_constraint(
      coverage_shortfall[s, v] >= min_exposures_per_student - sum_expr(x[s, d, v], d = day_ids),
      s = student_ids,
      v = services_available_at_least_once
    ) %>%

    # Penalize missing the total emphasized-service target.
    add_constraint(
      emphasis_shortfall[s, v] >= emphasis_target[s, v] - sum_expr(x[s, d, v], d = day_ids),
      s = student_ids,
      v = service_ids
    )

  # Penalize missing weekly emphasized-service targets. These constraints are
  # added week-by-week so that emphasis is encouraged in each available week,
  # rather than only as a total across the full rotation.
  for (w_i in seq_len(n_rotation_weeks)) {
    week_day_ids <- day_ids[week_ids == w_i]

    model <- model %>%
      add_constraint(
        emphasis_week_shortfall[s, w_i, v] >=
          emphasis_week_target[s, w_i, v] - sum_expr(x[s, d, v], d = week_day_ids),
        s = student_ids,
        v = service_ids
      )
  }

  # Require non-emphasis students to see each available service at least once.
  # Emphasis students can miss some other services if that is needed to satisfy
  # their emphasis preference.
  if (require_all_available && length(hard_exposure_students) > 0) {
    for (v in services_available_at_least_once) {
      model <- model %>%
        add_constraint(
          sum_expr(x[s, d, v], d = day_ids) >= min_exposures_per_student,
          s = hard_exposure_students
        )
    }
  }

  model <- model %>%
    set_objective(
      back_to_back_penalty *
        sum_expr(back_to_back_weight[s, v] * y[s, d, v], s = student_ids, d = day_ids[-1], v = service_ids) +
        imbalance_penalty *
        sum_expr(excess[s, v], s = student_ids, v = service_ids) +
        coverage_shortfall_penalty *
        sum_expr(coverage_relaxed[s, v] * coverage_shortfall[s, v], s = student_ids, v = service_ids) +
        emphasis_shortfall_penalty *
        sum_expr(emphasis_active[s, v] * emphasis_shortfall[s, v], s = student_ids, v = service_ids) +
        emphasis_shortfall_penalty *
        sum_expr(emphasis_week_active[s, w, v] * emphasis_week_shortfall[s, w, v], s = student_ids, w = seq_len(n_rotation_weeks), v = service_ids),
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

  emphasis_summary <- NULL
  if (!is.null(service_emphasis) && nrow(as.data.frame(service_emphasis)) > 0) {
    emphasis_summary <- expand.grid(
      student_id = student_ids,
      service_id = service_ids,
      stringsAsFactors = FALSE
    ) %>%
      mutate(
        student = students[student_id],
        service = services[service_id],
        target = emphasis_target[cbind(student_id, service_id)]
      ) %>%
      filter(target > 0) %>%
      left_join(
        long_schedule %>% count(student, service, name = "scheduled"),
        by = c("student", "service")
      ) %>%
      mutate(
        scheduled = ifelse(is.na(scheduled), 0L, scheduled),
        shortfall = pmax(target - scheduled, 0)
      ) %>%
      select(student, service, target, scheduled, shortfall)
  }

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

  service_colors <- get_service_colors(services)
  schedule_plot <- make_schedule_plot(
    long_schedule = long_schedule,
    service_colors = service_colors
  )

  list(
    long = long_schedule,
    wide = wide_schedule,
    emphasis_summary = emphasis_summary,
    plot = schedule_plot,
    service_colors = service_colors
  )
}

# -----------------------------
# Shiny UI
# -----------------------------

default_services <- c(
  "GU",
  "Breast",
  "GI",
  "H&N",
  "CNS/Peds",
  "Gyn/Peds/Lymph",
  "Thoracic/Sarc/Lymph"
)

ui <- fluidPage(
  titlePanel("Student Rotation Scheduler"),

  sidebarLayout(
    sidebarPanel(
      h4("Students"),
      textAreaInput(
        inputId = "students_text",
        label = "Student names, separated by commas or new lines",
        value = "Student A\nStudent B\nStudent C",
        rows = 4
      ),

      h4("Rotation dates"),
      dateInput(
        inputId = "start_date",
        label = "Start date",
        value = Sys.Date(),
        weekstart = 1
      ),
      selectInput(
        inputId = "n_weeks",
        label = "Number of weeks",
        choices = c("2 weeks" = 2, "4 weeks" = 4),
        selected = 2
      ),
      numericInput(
        inputId = "days_per_week",
        label = "Rotation days per week",
        value = 5,
        min = 1,
        max = 5,
        step = 1
      ),

      h4("Services"),
      checkboxGroupInput(
        inputId = "base_services",
        label = "Possible services",
        choices = default_services,
        selected = default_services
      ),
      textAreaInput(
        inputId = "extra_services",
        label = "Add new services for this run, separated by commas or new lines",
        value = "",
        placeholder = "Example:\nBrachytherapy\nLymphoma",
        rows = 3
      ),

      h4("Locations"),
      fileInput(
        inputId = "locations_file",
        label = "Optional locations.csv override",
        accept = c(".csv")
      ),
      helpText("By default, the app uses locations.csv bundled in the same folder as app.R. Uploading a file here temporarily overrides that bundled file. Expected columns: service, Monday, Tuesday, Wednesday, Thursday, Friday. If a location value is 'academic', that service-day is treated as unavailable and will not be assigned."),

      h4("Optional service emphasis"),
      helpText("Optionally choose one emphasized service per student. Emphasized students may receive that service more often and may miss some other services."),
      uiOutput("student_emphasis_ui"),
      numericInput(
        inputId = "emphasis_per_week",
        label = "Target emphasized-service assignments per week",
        value = 2,
        min = 1,
        max = 5,
        step = 1
      ),
      checkboxInput(
        inputId = "allow_emphasis_back_to_back",
        label = "Allow back-to-back days for emphasized services",
        value = TRUE
      ),

      h4("Schedule rules"),
      checkboxInput(
        inputId = "require_all_available",
        label = "Require each student to see each available service",
        value = TRUE
      ),
      numericInput(
        inputId = "min_exposures",
        label = "Minimum exposures per student per available service",
        value = 1,
        min = 1,
        max = 10,
        step = 1
      ),
      numericInput(
        inputId = "back_to_back_penalty",
        label = "Back-to-back repeat penalty",
        value = 100,
        min = 0,
        step = 10
      ),
      numericInput(
        inputId = "imbalance_penalty",
        label = "Imbalance penalty",
        value = 1,
        min = 0,
        step = 1
      ),
      actionButton("run_schedule", "Create schedule", class = "btn-primary"),
      br(), br(),
      downloadButton("download_wide", "Download wide CSV"),
      downloadButton("download_long", "Download long CSV"),
      downloadButton("download_plot", "Download schedule plot PNG"),
      downloadButton("download_locations_template", "Download locations template")
    ),

    mainPanel(
      h3("Weekly service availability"),
      p("Choose which services are available during each week. These choices determine what the scheduler is allowed to use."),
      uiOutput("weekly_availability_ui"),

      hr(),

      h3("Schedule"),
      verbatimTextOutput("status_text"),
      DTOutput("schedule_table"),

      h3("Schedule plot"),
      plotOutput("schedule_plot", height = "900px"),

      h3("Exposure counts"),
      DTOutput("counts_table"),

      h3("Emphasis summary"),
      DTOutput("emphasis_table"),

      h3("Back-to-back repeats"),
      DTOutput("repeat_table"),

      hr(),

      h3("Plot from edited wide schedule"),
      p("Upload a wide schedule CSV after making manual edits. The app will regenerate the same color-coded plot without rerunning the scheduler."),
      fileInput(
        inputId = "manual_wide_file",
        label = "Upload edited wide schedule CSV",
        accept = c(".csv")
      ),
      helpText("Expected format: one date column, optional week column, and one column per student. Student cells should contain either 'Service' or 'Service - Location'."),
      verbatimTextOutput("manual_plot_status"),
      plotOutput("manual_schedule_plot", height = "900px"),
      downloadButton("download_manual_plot", "Download edited schedule plot PNG")
    )
  )
)

# -----------------------------
# Shiny server
# -----------------------------

server <- function(input, output, session) {

  selected_services <- reactive({
    extra <- parse_list_input(input$extra_services)

    services <- unique(c(input$base_services, extra))
    services <- services[nzchar(services)]

    services
  })

  output$weekly_availability_ui <- renderUI({
    services <- selected_services()
    n_weeks <- as.integer(input$n_weeks)

    if (length(services) == 0) {
      return(helpText("Select or add at least one service."))
    }

    tagList(
      lapply(seq_len(n_weeks), function(w) {
        checkboxGroupInput(
          inputId = paste0("week_services_", w),
          label = paste("Week", w, "available services"),
          choices = services,
          selected = services
        )
      })
    )
  })

  output$student_emphasis_ui <- renderUI({
    students <- parse_list_input(input$students_text)
    services <- selected_services()

    if (length(students) == 0 || length(services) == 0) {
      return(helpText("Enter students and select services to enable emphasis options."))
    }

    tagList(
      lapply(seq_along(students), function(i) {
        selectInput(
          inputId = paste0("emphasis_service_", i),
          label = paste(students[i], "emphasis service"),
          choices = c("No emphasis" = "", services),
          selected = ""
        )
      })
    )
  })

  result <- eventReactive(input$run_schedule, {
    students <- parse_list_input(input$students_text)
    services <- selected_services()
    n_weeks <- as.integer(input$n_weeks)
    days_per_week <- as.integer(input$days_per_week)
    days <- make_days(n_weeks, days_per_week)
    locations <- read_locations_file(input$locations_file)

    emphasis <- tibble(
      student = character(0),
      service = character(0),
      target_per_week = numeric(0)
    )

    if (length(students) > 0) {
      emphasis <- tibble(
        student = students,
        service = vapply(seq_along(students), function(i) {
          value <- input[[paste0("emphasis_service_", i)]]
          if (is.null(value)) "" else value
        }, character(1)),
        target_per_week = input$emphasis_per_week
      ) %>%
        filter(!is.na(service), service != "")
    }

    validate(
      need(length(students) >= 1, "Enter at least one student."),
      need(length(services) >= 1, "Select or add at least one service."),
      need(days_per_week >= 1, "Days per week must be at least 1."),
      need(days_per_week <= 5, "Locations are currently set up for Monday-Friday only.")
    )

    availability <- make_availability(
      days = days,
      services = services,
      n_weeks = n_weeks,
      days_per_week = days_per_week,
      input = input
    )

    out <- tryCatch(
      {
        sched <- schedule_rotation(
          students = students,
          services = services,
          days = days,
          availability = availability,
          start_date = input$start_date,
          locations = locations,
          days_per_week = days_per_week,
          require_all_available = isTRUE(input$require_all_available),
          min_exposures_per_student = input$min_exposures,
          service_emphasis = emphasis,
          emphasis_per_week = input$emphasis_per_week,
          allow_emphasis_back_to_back = isTRUE(input$allow_emphasis_back_to_back),
          back_to_back_penalty = input$back_to_back_penalty,
          imbalance_penalty = input$imbalance_penalty
        )

        counts <- sched$long %>%
          count(student, service, name = "n") %>%
          arrange(student, service)

        repeats <- sched$long %>%
          arrange(student, day_num) %>%
          group_by(student) %>%
          mutate(previous_service = lag(service)) %>%
          ungroup() %>%
          filter(service == previous_service) %>%
          select(date_label, student, service, location)

        message <- "Schedule created successfully. Academic-location service-days were treated as unavailable."
        if (nrow(emphasis) > 0) {
          message <- paste0(
            message,
            " Service emphasis was used as a soft preference; emphasized students may miss some other services. Back-to-back days for emphasized services are allowed if selected."
          )
        }

        list(
          ok = TRUE,
          message = message,
          sched = sched,
          counts = counts,
          emphasis = sched$emphasis_summary,
          repeats = repeats
        )
      },
      error = function(e) {
        list(
          ok = FALSE,
          message = conditionMessage(e),
          sched = NULL,
          counts = NULL,
          emphasis = NULL,
          repeats = NULL
        )
      }
    )

    out
  })


  manual_plot_result <- reactive({
    req(input$manual_wide_file)

    out <- tryCatch(
      {
        wide_schedule <- read_manual_wide_schedule_file(input$manual_wide_file)

        long_schedule <- wide_schedule_to_long_for_plot(
          wide_schedule = wide_schedule,
          days_per_week = as.integer(input$days_per_week)
        )

        schedule_plot <- make_schedule_plot(
          long_schedule = long_schedule,
          service_colors = get_service_colors(unique(long_schedule$service))
        )

        list(
          ok = TRUE,
          message = paste0(
            "Plot generated from uploaded wide schedule. Rows: ",
            dplyr::n_distinct(long_schedule$date_label),
            "; students: ",
            dplyr::n_distinct(long_schedule$student),
            "."
          ),
          long = long_schedule,
          plot = schedule_plot
        )
      },
      error = function(e) {
        list(
          ok = FALSE,
          message = conditionMessage(e),
          long = NULL,
          plot = NULL
        )
      }
    )

    out
  })

  output$status_text <- renderText({
    res <- result()
    res$message
  })

  output$schedule_table <- renderDT({
    res <- result()
    req(res$ok)

    datatable(
      res$sched$wide,
      rownames = FALSE,
      options = list(pageLength = 25, scrollX = TRUE)
    )
  })


  output$schedule_plot <- renderPlot({
    res <- result()
    req(res$ok)
    print(res$sched$plot)
  }, res = 120)

  output$counts_table <- renderDT({
    res <- result()
    req(res$ok)

    datatable(
      res$counts,
      rownames = FALSE,
      options = list(pageLength = 25)
    )
  })

  output$emphasis_table <- renderDT({
    res <- result()
    req(res$ok)

    emphasis <- res$emphasis

    if (is.null(emphasis) || nrow(emphasis) == 0) {
      emphasis <- tibble(
        student = character(0),
        service = character(0),
        target = numeric(0),
        scheduled = integer(0),
        shortfall = numeric(0)
      )
    }

    datatable(
      emphasis,
      rownames = FALSE,
      options = list(pageLength = 25)
    )
  })

  output$repeat_table <- renderDT({
    res <- result()
    req(res$ok)

    repeats <- res$repeats

    if (nrow(repeats) == 0) {
      repeats <- tibble(
        date_label = character(0),
        student = character(0),
        service = character(0),
        location = character(0)
      )
    }

    datatable(
      repeats,
      rownames = FALSE,
      options = list(pageLength = 25)
    )
  })

  output$download_wide <- downloadHandler(
    filename = function() {
      "rotation_schedule_wide.csv"
    },
    content = function(file) {
      res <- result()
      req(res$ok)
      write.csv(res$sched$wide, file, row.names = FALSE)
    }
  )

  output$download_long <- downloadHandler(
    filename = function() {
      "rotation_schedule_long.csv"
    },
    content = function(file) {
      res <- result()
      req(res$ok)
      write.csv(res$sched$long, file, row.names = FALSE)
    }
  )

  output$download_plot <- downloadHandler(
    filename = function() {
      "rotation_schedule_plot.png"
    },
    content = function(file) {
      res <- result()
      req(res$ok)
      n_students <- dplyr::n_distinct(res$sched$long$student)
      n_dates <- dplyr::n_distinct(res$sched$long$date_label)
      ggplot2::ggsave(
        filename = file,
        plot = res$sched$plot,
        width = max(8, n_students * 2.2),
        height = max(6, n_dates * 0.55),
        dpi = 300,
        bg = "white"
      )
    }
  )


  output$manual_plot_status <- renderText({
    if (is.null(input$manual_wide_file)) {
      return("Upload an edited wide schedule CSV to generate a plot.")
    }

    res <- manual_plot_result()
    res$message
  })

  output$manual_schedule_plot <- renderPlot({
    res <- manual_plot_result()
    req(res$ok)
    print(res$plot)
  }, res = 120)

  output$download_manual_plot <- downloadHandler(
    filename = function() {
      "edited_rotation_schedule_plot.png"
    },
    content = function(file) {
      res <- manual_plot_result()
      req(res$ok)
      n_students <- dplyr::n_distinct(res$long$student)
      n_dates <- dplyr::n_distinct(res$long$date_label)
      ggplot2::ggsave(
        filename = file,
        plot = res$plot,
        width = max(8, n_students * 2.2),
        height = max(6, n_dates * 0.55),
        dpi = 300,
        bg = "white"
      )
    }
  )

  output$download_locations_template <- downloadHandler(
    filename = function() {
      "locations_template.csv"
    },
    content = function(file) {
      services <- selected_services()
      template <- data.frame(
        service = services,
        Monday = "",
        Tuesday = "",
        Wednesday = "",
        Thursday = "",
        Friday = "",
        check.names = FALSE
      )
      write.csv(template, file, row.names = FALSE, na = "")
    }
  )
}

shinyApp(ui = ui, server = server)
