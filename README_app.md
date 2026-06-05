# Student Rotation Scheduler Shiny App

This Shiny app creates daily student rotation schedules across available clinical services.

The app is intended for short student rotations, most commonly 2-week rotations, but it can also be used for 4-week rotations. Students switch services each day, and the scheduler tries to create a valid schedule while avoiding unnecessary back-to-back repeats.

## Accessing the App

You can [access the app here.](https://s-carson-callahan.shinyapps.io/studentScheduleMaker/)

## What the App Does

The scheduler creates a rotation schedule that aims to:

- assign each student to exactly one service per day
- prevent more than one student from being assigned to the same service on the same day when enough services are available
- allow multiple students on the same available service if there are fewer available services than students on a given day
- use only services that are marked as available
- treat service-days marked as `Academic` as unavailable
- ensure each student sees each available service at least once, when feasible
- optionally prioritize an emphasized service for each student
- avoid assigning the same student to the same service on back-to-back days when possible
- allow back-to-back days for a student's emphasized service, when enabled
- display the schedule using real dates, such as `Monday, January 1`
- append campus/location information to each service assignment

## Step-by-Step Use

### 1. Enter Student Names

Enter the student names in the student text box.

Names can be separated by commas or placed on separate lines.

Example:

```text
Student A
Student B
Student C
```

### 2. Choose Rotation Dates and Length

Choose the rotation start date.

The app uses weekdays only. If the selected start date falls on a weekend, the schedule begins on the next weekday.

Select whether the rotation is:

- 2 weeks
- 4 weeks

You can also adjust the number of rotation days per week. The default is 5 days per week.

### 3. Select Possible Services

Use the service checkboxes to select the services that may be used for this schedule.

Default service options include:

- GU
- Breast
- GI
- H&N
- CNS/Peds
- Gyn/Peds/Lymph
- Thoracic/Sarc/Lymph

### 4. Add Any One-Off Services

If a service is needed for only this particular schedule, enter it in the additional services text box.

Multiple added services can be separated by commas or placed on separate lines.

Example:

```text
Brachytherapy
Lymphoma
```

These added services will appear as options for the current scheduling run.

### 5. Review Locations

The hosted app can include a bundled `locations.csv` file. In normal use, users do not need to upload a locations file.

The app first looks for a bundled file called:

```text
locations.csv
```

in the same folder as `app.R`.

If you upload a file using the optional `locations.csv` upload box, the uploaded file overrides the bundled file for that session only.

The expected format is:

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

The final schedule displays assignments like:

```text
GI - Main Campus
GU - East Campus
```

### 6. Set Weekly Service Availability

For each week, select which services are available during that week.

The scheduler will only assign students to services that are checked as available for that week and not marked as `Academic` for that weekday.

### 7. Optional Service Emphasis

For each student, you can optionally choose one service to emphasize.

For example:

- Student A: `GI`
- Student B: `H&N`
- Student C: no emphasis

The app will strongly try to schedule each student on their emphasized service a target number of times per week.

The default target is usually 2 emphasized-service assignments per week. If the emphasized service is not available in a given week, that week does not count against the target.

Service emphasis is intentionally weighted strongly. Missing an emphasis target is considered more important than ordinary back-to-back repeats or mild service imbalance.

When service emphasis is used, a student may miss some other available services in order to receive more time on the emphasized service.

The app also includes an option to allow back-to-back days for emphasized services. This should usually be left enabled, because emphasized services may otherwise be difficult to schedule 2-3 times per week.

### 8. Review Schedule Rules

The default settings require each student to see each available service at least once, when feasible.

The app also includes penalty settings for:

- back-to-back repeats
- service imbalance
- emphasis shortfall

Most users should leave these settings at their defaults.

### 9. Create the Schedule

Click **Create schedule**.

If a valid schedule is found, the schedule table will appear.

If a valid schedule cannot be created, the app will show an error message explaining the issue. Common causes include a required service not being available enough times after excluding `Academic` days.

## Academic Locations

If a location value is `Academic`, that service-day is treated as unavailable.

For example:

```csv
service,Monday,Tuesday,Wednesday,Thursday,Friday
CNS/Peds,Academic,Main Campus,Main Campus,Main Campus,Academic
```

This means `CNS/Peds` will not be scheduled on Mondays or Fridays. There is no fallback behavior for `Academic` days; they are fully excluded.

## Multiple Students on One Service

The app normally prevents more than one student from being assigned to the same service on the same day.

However, if a day has fewer available services than students, the app allows multiple students to share an available service on that day. This prevents schedules from failing simply because, for example, there are 4 students but only 3 available services on a particular day.

This fallback only applies when the number of available services on a day is less than the number of students.

## Service Emphasis Details

Service emphasis is optional and is set separately for each student.

The emphasis target is weekly. If a student emphasizes `GI` with a target of 2, the optimizer tries to schedule that student on `GI` twice in each week where `GI` is available.

If `GI` is unavailable in week 2, the week 2 target becomes 0. The app will still strongly pursue the week 1 target if `GI` is available in week 1.

Emphasis is a soft preference rather than an absolute guarantee. It is weighted strongly, but the schedule must still obey hard constraints such as:

- one assignment per student per day
- no scheduling on unavailable services
- no scheduling on `Academic` service-days
- daily service capacity rules

Back-to-back emphasized-service days can be allowed. When enabled, the usual back-to-back repeat penalty does not apply to a student's emphasized service.

## Outputs

The app provides four main outputs:

### Schedule

This is the main schedule table, with one row per date and one column per student.

Each assignment includes the service and, when available, the location.

Example:

```text
GI - Main Campus
Breast - East Campus
```

### Exposure Counts

This table shows how many times each student is assigned to each service.

### Emphasis Summary

This table shows each student's emphasized service, the weekly target, and the achieved number of emphasized-service assignments.

### Back-to-Back Repeats

This table shows any cases where a student is assigned to the same service on consecutive days.

Ideally, this table should be empty for non-emphasized services. Back-to-back repeats may appear for emphasized services if that option is enabled.

## Downloads

The app provides two CSV download options.

### Wide CSV

The **wide** download is probably what most users want.

It gives a readable schedule with one row per date and one column per student.

Example format:

```text
week,date,Student A,Student B,Student C
1,"Monday, January 1",GU - Main Campus,Breast - Main Campus,GI - East Campus
1,"Tuesday, January 2",GI - Main Campus,H&N - West Campus,GU - Main Campus
```

This format is easiest to read, print, or share.

### Long CSV

The **long** download is also provided.

It gives one row per student-day assignment.

Example format:

```text
week,date_label,date,weekday,day_num,day,student,service,location,is_academic_location,assignment
1,"Monday, January 1",2026-01-01,Monday,1,Day 1,Student A,GU,Main Campus,FALSE,GU - Main Campus
```

This format is useful for data analysis, checking counts, identifying shared service-days, reviewing emphasis performance, or reshaping the schedule later.

## Hosting Notes

To use a built-in locations file when hosting the app, include `locations.csv` in the same directory as `app.R`.

Example app folder:

```text
studentScheduleMaker/
├── app.R
└── locations.csv
```

When deployed, the app will automatically read the bundled `locations.csv`.

The optional upload field remains available as an override for testing or one-off changes.

## Feasibility Notes

Some combinations of students, services, and availability are mathematically impossible.

The app permits multiple students to share a service when there are fewer available services than students on a given day. Therefore, a day with fewer services than students is no longer automatically infeasible.

However, the schedule can still be infeasible if a required service is not available enough times after excluding unavailable and `Academic` service-days.

When service emphasis is used, the app prioritizes the emphasized service strongly. This may mean the emphasized student does not see every other available service.

When no feasible schedule exists, try one of the following:

- make more services available in one or more weeks
- reduce the number of required exposures
- allow fewer services to be required
- extend the rotation length
- reduce the number of students assigned to the block
- lower the emphasis target
