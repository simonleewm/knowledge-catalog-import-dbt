{#
  Override dbt's default schema naming.

  Default dbt behaviour:  <profile dataset>_<custom schema>   (e.g. dbt_bq_demo_landing)
  This project:           <custom schema>                     (e.g. landing)

  so that each layer lands in a dataset with the exact name configured via
  +schema in dbt_project.yml (sources, landing, raw, curated, conformed).
  Nodes without a custom schema fall back to the profile's dataset.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}

    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}
