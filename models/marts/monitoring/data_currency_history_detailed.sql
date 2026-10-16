{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='data_currency_history_detail_id'
    )
}}

{% set build_missing_date = var('BuildMissingDate', none) %}

with monitoring_history as (

    select * from {{ ref('stg_monitoring__data_currency_history') }}

),

monitoring_reference as (

    select * from {{ ref('stg_monitoring__data_currency_reference') }}

),

checks_in_scope as (

    select
        {{ dbt_utils.generate_surrogate_key([
            'history.database_name',
            'history.schema_name',
            'history.table_name',
            'reference.column_name',
            'history.checked_on'
        ]) }} as data_currency_history_detail_id,
        coalesce(history.server_name, reference.server_name) as server_name,
        reference.database_name,
        reference.schema_name,
        reference.table_name,
        reference.column_name,
        case
            when history.data_as_at is null then '1900-01-01 00:00:00'::timestamp_ntz
            when reference.requires_utc_adjustment = 'Y'
                and history.data_as_at <> '1900-01-01 00:00:00'::timestamp_ntz
                then convert_timezone('UTC', 'Pacific/Auckland', history.data_as_at::timestamp_ntz)
            else history.data_as_at::timestamp_ntz
        end as data_as_at,
        history.checked_on::timestamp_ntz as checked_on,
        history.row_count,
        reference.row_check,
        reference.expected_run_days_prior,
        case
            when reference.data_timing ilike '%Real%'
                then timestamp_ntz_from_parts(
                    '1900-01-01'::date,
                    time_from_parts(
                        date_part('hour', history.checked_on),
                        date_part('minute', history.checked_on),
                        0
                    )
                )
            else timestamp_ntz_from_parts(
                '1900-01-01'::date,
                reference.expected_run_latest_time::time
            )
        end as expected_run_latest_time,
        dateadd(
            'minute',
            -datediff(
                'minute',
                '00:00:00'::time,
                reference.expected_run_acceptable_lag::time
            ),
            timestamp_ntz_from_parts(
                dateadd(
                    'day',
                    -(
                        reference.expected_run_days_prior
                        + case
                            when reference.data_entry_usually_business_hours = 'Y'
                                and reference.expected_run_days_prior = 0 then 1
                            when reference.runs_sunday = 'N'
                                and dayofweekiso(history.checked_on) = 1
                                and reference.data_timing not ilike '%Real%' then 1
                            else 0
                        end
                    ),
                    history.checked_on::date
                ),
                case
                    when reference.data_entry_usually_business_hours = 'Y' then '17:00:00'::time
                    when reference.data_timing ilike '%Real%' then history.checked_on::time
                    else reference.expected_run_latest_time::time
                end
            )
        ) as expected_run_datetime_min,
        reference.data_timing,
        reference.runs_sunday,
        reference.data_entry_usually_business_hours,
        timestamp_ntz_from_parts(
            dateadd(
                'day',
                -(
                    reference.expected_run_days_prior
                    + case
                        when reference.runs_sunday = 'N'
                            and dayofweekiso(history.checked_on) = 1
                            and reference.data_timing not ilike '%Real%' then 1
                        else 0
                    end
                ),
                history.checked_on::date
            ),
            case
                when reference.data_timing ilike '%Real%' then history.checked_on::time
                else reference.expected_run_latest_time::time
            end
        ) as job_1_expected_run_start_datetime,
        reference.job_name_1,
        reference.job_type_1,
        reference.job_name_2,
        reference.job_type_2
    from monitoring_history as history
    inner join monitoring_reference as reference
        on history.database_name = reference.database_name
        and history.schema_name = reference.schema_name
        and history.table_name = reference.table_name
    where history.checked_on::date between reference.expected_run_schedule_start
        and reference.expected_run_schedule_end
    {% if is_incremental() %}
        and (
            history.checked_on::date = current_date()
            {% if build_missing_date is not none %}
                or history.checked_on::date = '{{ build_missing_date }}'::date
            {% endif %}
        )
    {% endif %}

),

checks_with_currency_status as (

    select
        *,
        data_as_at::date as data_as_at_date,
        data_as_at::time as data_as_at_time,
        checked_on::date as checked_on_date,
        checked_on::time as checked_on_time,
        case
            when expected_run_days_prior = -100
                or data_as_at = '1900-01-01 00:00:00'::timestamp_ntz
                then 'DataAsAt Unavailable'
            when dateadd(
                'hour',
                -{{ var('Tolerance_Verify', 3) }},
                expected_run_datetime_min
            ) > data_as_at then 'DataAsAt > Tolerance'
            when data_as_at < dateadd(
                'minute',
                -{{ var('Tolerance_OK', 30) }},
                expected_run_datetime_min
            ) then 'DataAsAt <= Tolerance'
            else 'DataAsAt OK'
        end as data_currency_check
    from checks_in_scope

),

maximum_row_counts as (

    select
        checks.data_currency_history_detail_id,
        max(history.row_count) as max_row_count_30_days
    from checks_with_currency_status as checks
    inner join monitoring_history as history
        on checks.database_name = history.database_name
        and checks.schema_name = history.schema_name
        and checks.table_name = history.table_name
        and history.checked_on < checks.checked_on
        and datediff('day', history.checked_on::date, checks.checked_on_date) < 30
    group by 1

),

maximum_row_count_dates as (

    select
        maximums.data_currency_history_detail_id,
        maximums.max_row_count_30_days,
        max(history.checked_on) as max_row_count_checked_on
    from maximum_row_counts as maximums
    inner join checks_with_currency_status as checks
        on maximums.data_currency_history_detail_id = checks.data_currency_history_detail_id
    inner join monitoring_history as history
        on checks.database_name = history.database_name
        and checks.schema_name = history.schema_name
        and checks.table_name = history.table_name
        and history.row_count = maximums.max_row_count_30_days
        and history.checked_on < checks.checked_on
    group by 1, 2

),

final as (

    select
        checks.data_currency_history_detail_id,
        checks.server_name,
        checks.database_name,
        checks.schema_name,
        checks.table_name,
        checks.column_name,
        checks.data_as_at,
        checks.checked_on,
        checks.data_as_at_date,
        checks.data_as_at_time,
        checks.checked_on_date,
        checks.checked_on_time,
        checks.row_count,
        checks.row_check,
        checks.expected_run_days_prior,
        checks.expected_run_latest_time,
        checks.expected_run_datetime_min,
        checks.data_currency_check,
        {{ var('Tolerance_Verify', 3) }} as tolerance_verify_hours,
        {{ var('Tolerance_OK', 30) }} as tolerance_ok_minutes,
        case
            when checks.row_check = 'Can Decrease'
                or maximums.max_row_count_checked_on is null
                then 'Row Count Can Decrease Or N/A'
            when maximums.max_row_count_30_days > checks.row_count
                then 'Row Count Less Than Expected'
            when maximums.max_row_count_30_days = checks.row_count
                then 'Row Count Same As 30 Day Max'
            else 'Row Count Has Increased'
        end as row_count_check,
        coalesce(maximums.max_row_count_30_days, 0) as max_row_count_30_days,
        coalesce(
            maximums.max_row_count_checked_on,
            '1900-01-01 00:00:00'::timestamp_ntz
        ) as max_row_count_checked_on,
        checks.data_timing,
        checks.runs_sunday,
        checks.data_entry_usually_business_hours,
        checks.job_1_expected_run_start_datetime,
        checks.job_name_1,
        checks.job_type_1,
        checks.job_name_2,
        checks.job_type_2
    from checks_with_currency_status as checks
    left join maximum_row_count_dates as maximums
        on checks.data_currency_history_detail_id = maximums.data_currency_history_detail_id

)

select * from final
