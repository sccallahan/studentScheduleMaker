# Student Rotation Scheduler

This R script creates daily student rotation schedules across multiple clinical services while enforcing basic scheduling rules. There is also an app [accessible here](https://s-carson-callahan.shinyapps.io/studentScheduleMaker/). Please see the [`README_app.md`](README_app.md) in this repo for more help with the app.

## Purpose

The scheduler is designed for 2–4 students rotating over a 2-week or 4-week block. Students switch services daily, and the schedule ensures that:

- each student is assigned to exactly one service per day
- no two students are assigned to the same service on the same day when there are enough available services
- if there are fewer available services than students on a given day, multiple students may be assigned to the same available service
- unavailable services are not assigned
- service-days marked as `Academic` in `locations.csv` are treated as unavailable
- each student sees each available service at least once, when feasible
- back-to-back repeats of the same service are avoided when possible
- schedules can be displayed using real calendar dates instead of only `Day 1`, `Day 2`, etc.
- service locations can be appended to the schedule using a `locations.csv` file

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
  "GU",
  "Breast",
  "GI",
  "H&N",
  "CNS/Peds",
  "Gyn/Peds/Lymph",
  "Thoracic/Sarc/Lymph"
)
```

Define the internal rotation days:

```r
days <- paste0("Day ", 1:10)
```

Optionally define a real calendar start date:

```r
start_date <- as.Date("2026-07-06")
```

The scheduler will use the first weekday on or after `start_date` and will skip weekends.

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
      week == 1 & service %in% c("GU", "Breast", "GI", "H&N", "CNS/Peds") ~ TRUE,
      week == 2 & service %in% c("GU", "GI", "H&N", "Gyn/Peds/Lymph", "Thoracic/Sarc/Lymph") ~ TRUE,
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
  start_date = start_date,
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

## Using Locations

The scheduler can append campus/location information to each service assignment.

Create a `locations.csv` file with one row per service and one column per weekday:

```csv
service,Monday,Tuesday,Wednesday,Thursday,Friday
GU,Main Campus,Main Campus,East Campus,East Campus,Main Campus
Breast,Main Campus,Main Campus,Main Campus,Main Campus,Main Campus
GI,Main Campus,East Campus,East Campus,Main Campus,Main Campus
H&N,West Campus,West Campus,Main Campus,Main Campus,Main Campus
CNS/Peds,Academic,Main Campus,Main Campus,Main Campus,Academic
Gyn/Peds/Lymph,Main Campus,Main Campus,Academic,Main Campus,Main Campus
Thoracic/Sarc/Lymph,East Campus,East Campus,Main Campus,Main Campus,Main Campus
```

Read the file into R:

```r
locations <- read.csv("locations.csv", stringsAsFactors = FALSE, check.names = FALSE)
```

Then pass it into the scheduler:

```r
sched <- schedule_rotation(
  students = students,
  services = services,
  days = days,
  availability = availability,
  start_date = start_date,
  locations = locations,
  days_per_week = 5,
  require_all_available = TRUE,
  min_exposures_per_student = 1
)
```

Assignments in the wide schedule will include both service and location, for example:

```text
GI - Main Campus
GU - East Campus
```

## Academic Locations

If a service location is listed as `Academic`, that service-day is treated as unavailable.

For example:

```csv
service,Monday,Tuesday,Wednesday,Thursday,Friday
CNS/Peds,Academic,Main Campus,Main Campus,Main Campus,Academic
```

This means `CNS/Peds` will not be scheduled on Mondays or Fridays. There is no fallback behavior for `Academic` days; they are fully excluded.

## Multiple Students on One Service

The scheduler normally prevents more than one student from being assigned to the same service on the same day.

However, if a day has fewer available services than students, that strict rule would make the schedule impossible. In that case, the scheduler allows multiple students to share an available service on that day.

For example, if there are 4 students but only 3 available services on a given day, the scheduler allows up to:

```r
ceiling(4 / 3)
```

students per available service that day.

This fallback only applies on days where the number of available services is less than the number of students.

## Output

The function returns a list with two tables:

- `sched$wide`: a readable schedule with one row per date and one column per student
- `sched$long`: a tidy table with one row per student-day assignment

The wide output is easiest to read or share. The long output is more useful for checking counts, filtering, and analysis.

With date and location features enabled, the long output includes columns such as:

- `week`
- `date_label`
- `date`
- `weekday`
- `day_num`
- `day`
- `student`
- `service`
- `location`
- `is_academic_location`
- `assignment`

## Checking the Schedule

Count how many times each student sees each service:

```r
sched$long %>%
  count(student, service) %>%
  arrange(student, service)
```

Check for same-day service sharing:

```r
sched$long %>%
  count(date_label, service) %>%
  filter(n > 1)
```

This should usually return zero rows. If rows are returned, it means multiple students were assigned to the same service on the same day, likely because there were fewer available services than students.

Check for back-to-back repeats:

```r
sched$long %>%
  arrange(student, day_num) %>%
  group_by(student) %>%
  mutate(previous_service = lag(service)) %>%
  filter(service == previous_service)
```

Check whether any academic-location assignments were used:

```r
sched$long %>%
  filter(is_academic_location)
```

This should return zero rows because `Academic` service-days are forbidden.

## Notes

The schedule may be infeasible if there are not enough available services or if a required service is not available enough times for every student to rotate through it.

Because the scheduler now permits multiple students to share a service when necessary, a day with fewer services than students is no longer automatically infeasible.

However, the schedule can still be infeasible if required services are too rare after excluding unavailable and `Academic` service-days.

If no feasible schedule exists, try one of the following:

- make more services available in one or more weeks
- reduce the number of required exposures
- allow fewer services to be required
- extend the rotation length
- reduce the number of students assigned to the block
