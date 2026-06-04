# Student Rotation Scheduler

This R script creates daily student rotation schedules across multiple clinical services while enforcing basic scheduling rules. There is also an app [accessible here](https://s-carson-callahan.shinyapps.io/Schedule-Maker/). Please see the [`README_app.md`](README_app.md) in this repo for more help with the app.

## Purpose

The scheduler is designed for 2–4 students rotating over a 2-week or 4-week block. Students switch services daily, and the schedule ensures that:

- each student is assigned to exactly one service per day
- no two students are assigned to the same service on the same day
- unavailable services are not assigned
- each student sees each available service at least once, when feasible
- back-to-back repeats of the same service are avoided when possible

## Requirements

Install the required R packages:

```r
install.packages(c(
  "ompr",
  "ompr.roi",
  "ROI.plugin.glpk",
  "dplyr",
  "tidyr"
))
```

Load the packages:

```r
library(ompr)
library(ompr.roi)
library(ROI.plugin.glpk)
library(dplyr)
library(tidyr)
```

## Basic Usage

Define the students:

```r
students <- c("Student A", "Student B", "Student C")
```

Define all possible services:

```r
services <- c(
  "Breast",
  "GI",
  "GU",
  "Thoracic",
  "CNS",
  "Peds",
  "Gyn"
)
```

Define the rotation days:

```r
days <- paste0("Day ", 1:10)
```

Create an availability table showing which services are available on each day:

```r
availability <- expand.grid(
  day = days,
  service = services,
  stringsAsFactors = FALSE
) %>%
  mutate(
    week = ifelse(day %in% paste0("Day ", 1:5), 1, 2),
    available = case_when(
      week == 1 & service %in% c("Breast", "GI", "GU", "Thoracic", "CNS") ~ TRUE,
      week == 2 & service %in% c("GI", "GU", "Thoracic", "Peds", "Gyn") ~ TRUE,
      TRUE ~ FALSE
    )
  ) %>%
  select(day, service, available)
```

Run the scheduler:

```r
sched <- schedule_rotation(
  students = students,
  services = services,
  days = days,
  availability = availability,
  require_all_available = TRUE,
  min_exposures_per_student = 1
)
```

View the schedule:

```r
sched$wide
```

View the long-format assignment table:

```r
sched$long
```

## Output

The function returns a list with two tables:

- `sched$wide`: a readable schedule with one row per day and one column per student
- `sched$long`: a tidy table with columns `day`, `student`, and `service`

## Checking the Schedule

Count how many times each student sees each service:

```r
sched$long %>%
  count(student, service) %>%
  arrange(student, service)
```

Check for accidental same-day service overlap:

```r
sched$long %>%
  count(day, service) %>%
  filter(n > 1)
```

This should return zero rows.

Check for back-to-back repeats:

```r
sched$long %>%
  arrange(student, day) %>%
  group_by(student) %>%
  mutate(previous_service = lag(service)) %>%
  filter(service == previous_service)
```

## Notes

The schedule may be infeasible if there are not enough available services on a given day or if a service is not available enough times for every student to rotate through it.

For example, if there are 3 students and every student must see `Peds` at least once, then `Peds` must be available on at least 3 separate days because only one student can be assigned to it per day.

If no feasible schedule exists, the function will stop with an error explaining the issue.
