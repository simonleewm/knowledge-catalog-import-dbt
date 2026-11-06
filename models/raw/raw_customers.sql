{{
    config(
        alias='customers'
    )
}}

-- Raw layer: typed, trimmed, case-normalised and de-duplicated customers.
-- One row per customer_id, keeping the record with the latest updated_at.

with landing as (

    select * from {{ ref('lnd_customers') }}

),

typed as (

    select
        safe_cast(trim(customer_id) as int64)          as customer_id,
        nullif(trim(first_name), '')                   as first_name,
        nullif(trim(last_name), '')                    as last_name,
        nullif(lower(trim(email)), '')                 as email,
        nullif(upper(trim(country_code)), '')          as country_code,
        safe_cast(trim(signup_date) as date)           as signup_date,
        nullif(lower(trim(status)), '')                as status,
        safe_cast(trim(updated_at) as timestamp)       as updated_at,
        _loaded_at
    from landing

),

deduplicated as (

    select *
    from typed
    -- a key that failed SAFE_CAST can never satisfy the not_null contract
    where customer_id is not null
    qualify row_number() over (
        partition by customer_id
        order by updated_at desc, _loaded_at desc
    ) = 1

)

select * from deduplicated
