{{
    config(
        alias='customers'
    )
}}

-- Landing layer: 1:1 copy of the source extract, no transformation.
-- Columns are listed explicitly (instead of SELECT *) so the schema is
-- stable and documented in _landing__models.yml.
--
-- Demo wiring: `sources.customers` is loaded by the `customers` seed in this
-- repo. The hint below gives dbt an explicit DAG edge seed -> this model, so
-- `dbt build` finishes the seed (which drops and recreates the table) before
-- reading it. In production the source is loaded externally and this line
-- would simply be removed. The data is still read via source() below.
-- depends_on: {{ ref('customers') }}

select
    customer_id,
    first_name,
    last_name,
    email,
    country_code,
    signup_date,
    status,
    updated_at,

    -- audit columns
    current_timestamp()  as _loaded_at,
    '{{ invocation_id }}' as _dbt_invocation_id

from {{ source('sources', 'customers') }}
