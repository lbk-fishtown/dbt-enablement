with source as (

    select * from {{ source('monitoring_dbo', 'data_currency_history') }}

),

renamed as (

    select
        ServerName as server_name,
        DbName as database_name,
        "SCHEMA" as schema_name,
        TableName as table_name,
        DataAsAt as data_as_at,
        CheckedOn as checked_on,
        coalesce(RowCounts, 0) as row_count
    from source

)

select * from renamed
