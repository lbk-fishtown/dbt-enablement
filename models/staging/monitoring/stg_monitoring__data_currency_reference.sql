with source as (

    select * from {{ source('monitoring_reference', 'data_currency_reference') }}

),

renamed as (

    select
        "SERVER" as server_name,
        DbName as database_name,
        "SCHEMA" as schema_name,
        TableName as table_name,
        ColumnChecked as column_name,
        RequiresUTCAdjustment as requires_utc_adjustment,
        RowCheck as row_check,
        ExptdRun_DaysPrior as expected_run_days_prior,
        ExptdRun_LatestTime as expected_run_latest_time,
        ExptdRun_AcceptableLagMins as expected_run_acceptable_lag,
        ExptdRun_ScheduleStart as expected_run_schedule_start,
        ExptdRun_ScheduleEnd as expected_run_schedule_end,
        DataTiming as data_timing,
        RunsSunday as runs_sunday,
        DataEntryUsuallyBusHrs as data_entry_usually_business_hours,
        JobName_1 as job_name_1,
        JobType_1 as job_type_1,
        JobName_2 as job_name_2,
        JobType_2 as job_type_2
    from source

)

select * from renamed
