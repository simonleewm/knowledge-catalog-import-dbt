{{
    config(
        alias='sales'
    )
}}

-- Landing layer: 1:1 copy of the source extract, no transformation.
--
-- Demo wiring: `sources.sales` is loaded by the `sales` seed in this repo; the
-- hint below makes `dbt build` run that seed before this model (see
-- lnd_customers.sql for details). The data is still read via source() below.
-- depends_on: {{ ref('sales') }}

select
    sale_id,
    customer_id,
    sale_ts,
    product_code,
    product_name,
    quantity,
    unit_price,
    currency,
    channel,
    updated_at,

    -- audit columns
    current_timestamp()  as _loaded_at,
    '{{ invocation_id }}' as _dbt_invocation_id

from {{ source('sources', 'sales') }}
