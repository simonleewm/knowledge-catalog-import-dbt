{{
    config(
        alias='sales'
    )
}}

-- Raw layer: typed, trimmed, case-normalised and de-duplicated sales.
-- One row per sale_id, keeping the record with the latest updated_at.

with landing as (

    select * from {{ ref('lnd_sales') }}

),

typed as (

    select
        safe_cast(trim(sale_id) as int64)              as sale_id,
        safe_cast(trim(customer_id) as int64)          as customer_id,
        safe_cast(trim(sale_ts) as timestamp)          as sale_ts,
        nullif(upper(trim(product_code)), '')          as product_code,
        nullif(trim(product_name), '')                 as product_name,
        safe_cast(trim(quantity) as int64)             as quantity,
        safe_cast(trim(unit_price) as numeric)         as unit_price,
        nullif(upper(trim(currency)), '')              as currency,
        nullif(lower(trim(channel)), '')               as channel,
        safe_cast(trim(updated_at) as timestamp)       as updated_at,
        _loaded_at
    from landing

),

deduplicated as (

    select *
    from typed
    -- a key that failed SAFE_CAST can never satisfy the not_null contract
    where sale_id is not null
    qualify row_number() over (
        partition by sale_id
        order by updated_at desc, _loaded_at desc
    ) = 1

)

select * from deduplicated
