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

# -----------------------------
# Scheduler function
# -----------------------------

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

      h4("Rotation length"),
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
        max = 7,
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
      downloadButton("download_long", "Download long CSV")
    ),

    mainPanel(
      h3("Weekly service availability"),
      p("Choose which services are available during each week. These choices determine what the scheduler is allowed to use."),
      uiOutput("weekly_availability_ui"),

      hr(),

      h3("Schedule"),
      verbatimTextOutput("status_text"),
      DTOutput("schedule_table"),

      h3("Exposure counts"),
      DTOutput("counts_table"),

      h3("Back-to-back repeats"),
      DTOutput("repeat_table")
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

  result <- eventReactive(input$run_schedule, {
    students <- parse_list_input(input$students_text)
    services <- selected_services()
    n_weeks <- as.integer(input$n_weeks)
    days_per_week <- as.integer(input$days_per_week)
    days <- make_days(n_weeks, days_per_week)

    validate(
      need(length(students) >= 1, "Enter at least one student."),
      need(length(services) >= 1, "Select or add at least one service."),
      need(days_per_week >= 1, "Days per week must be at least 1.")
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
          require_all_available = isTRUE(input$require_all_available),
          min_exposures_per_student = input$min_exposures,
          back_to_back_penalty = input$back_to_back_penalty,
          imbalance_penalty = input$imbalance_penalty
        )

        counts <- sched$long %>%
          count(student, service, name = "n") %>%
          arrange(student, service)

        repeats <- sched$long %>%
          mutate(day_num = as.integer(gsub("[^0-9]", "", day))) %>%
          arrange(student, day_num) %>%
          group_by(student) %>%
          mutate(previous_service = lag(service)) %>%
          ungroup() %>%
          filter(service == previous_service) %>%
          select(day, student, service)

        list(
          ok = TRUE,
          message = "Schedule created successfully.",
          sched = sched,
          counts = counts,
          repeats = repeats
        )
      },
      error = function(e) {
        list(
          ok = FALSE,
          message = conditionMessage(e),
          sched = NULL,
          counts = NULL,
          repeats = NULL
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

  output$counts_table <- renderDT({
    res <- result()
    req(res$ok)

    datatable(
      res$counts,
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
        day = character(0),
        student = character(0),
        service = character(0)
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
}

shinyApp(ui = ui, server = server)
