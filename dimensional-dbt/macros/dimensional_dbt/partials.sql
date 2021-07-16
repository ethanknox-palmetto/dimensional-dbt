{%- macro _truncate_snapshots(source, unique_key, precision='hour') -%}
    {#/* reduces the snapshot granularity to the given precision, and corrects the min/max
         to kimball standard beginning-of-time/end-of-time
        Args:
            source: the cte name or source name of a prepaired DBT snapshot.
            unique_key: the column or expression to uniquely identify same-object rows.
            precision: the level of truncation for each record. 
            One of [these](https://docs.snowflake.com/en/sql-reference/functions-date-time.html#label-supported-date-time-parts)
        Returns:
            a complete select with the added columns dimensional_dbt_valid_to
            and dimensional_dbt_valid_from, where earliest and latest values are corrected.
    */#}

    WITH 
        earliest_{{ source }} AS (
            SELECT 
                {{ unique_key }} AS unique_key
                , DATE_TRUNC('{{precision}}', MIN(dbt_updated_at)) AS earliest_dbt_updated_at
            FROM 
                {{ source }}
            GROUP BY 1
        )

        ,truncated_{{ source }} AS (
            SELECT
                {{ unique_key }} AS unique_key
                ,dbt_updated_at
                ,RANK() OVER (PARTITION BY unique_key, DATE_TRUNC('{{precision}}', dbt_updated_at) ORDER BY dbt_updated_at DESC ) AS dimensional_dbt_recency
            FROM
                {{ source }} AS source
        )
    SELECT
        source.*
        ,CASE 
            WHEN DATE_TRUNC('{{precision}}', dbt_valid_from ) = earliest_dbt_updated_at THEN '0000-01-01'::TIMESTAMP_NTZ
            ELSE DATE_TRUNC('{{precision}}', dbt_valid_from )
        END AS dimensional_dbt_valid_from
        ,IFNULL(DATE_TRUNC('{{precision}}', dbt_valid_to ), '9999-12-31'::TIMESTAMP_NTZ) AS dimensional_dbt_valid_to
    FROM
        {{ source }} source
    RIGHT JOIN
        truncated_{{ source }} deduplicated
    ON 
        {{ unique_key }} = deduplicated.unique_key
    AND
        source.dbt_updated_at = deduplicated.dbt_updated_at
    JOIN
    earliest_{{ source }}
    ON 
        1=1
    WHERE 
        dimensional_dbt_recency = 1
{%- endmacro -%}


{%- macro _partial_spine(direction, unique_key, truncated_source) -%}
    {#/* Partial for iscolating spine vals.*/#}
    SELECT
	    dimensional_dbt_valid_{{ direction }} AS spine_value
		, {{ unique_key }}
    FROM 
        {{ truncated_source }}
{%- endmacro -%}


{%- macro _generate_spine(truncated_source, unique_key) -%}
    {#/* Creates a standardized spine to host the disperate dimensions against.
        Args:
            truncated_source: the cte name or source name of dimensional_dbt snapshot.
            unique_key: the column or expression to uniquely identify same-object rows.
        Returns:
            a complete select with all the valid to-from date values.
    */#}
        WITH 
        {{ truncated_source }}_from_spine AS (
            {{ dimensional_dbt._partial_spine('from', unique_key, truncated_source) }}
        )
        ,{{ truncated_source }}_to_spine AS (
            {{ dimensional_dbt._partial_spine('to', unique_key, truncated_source) }}
        )

        SELECT
            DISTINCT spine_value
            , {{ unique_key }} AS unique_key
        FROM {{ truncated_source }}_from_spine

        UNION

        SELECT 
            DISTINCT spine_value
            , {{ unique_key }} AS unique_key
        FROM {{ truncated_source }}_to_spine
{%- endmacro -%}


{%- macro _merge_spines(spine_sources) -%}
    {#/* Creates a single spine from many spines.
        Args:
            spine_sources: an array of source or cte names for spines
        Returns:
            a complete select of spine values.
    */#}
    WITH union_of_spines AS (
        {% for spine in spine_sources %}
            SELECT
                unique_key
                ,spine_value
            FROM
                {{ spine }}
            {% if not loop.last %}
            UNION ALL
            {% endif %}
        {% endfor %}
    )
    SELECT
         spine_value
        , unique_key
    FROM
        union_of_spines
{%- endmacro -%}


{%- macro _create_duration_windows_from_spine(spine) -%}
    {#/* Creates a spine of valid_to => valid_from windows
        from a given spine.
        Args:
            spine: a valid dimensional_dbt spine with columns `spine_value` and `unique_key`
        Returns:
            a complete select of spine values windowed into durations.
    */#}
    WITH
    ordered_spine AS (
        SELECT 
            spine_value
            ,unique_key
        FROM
            {{ spine }}
        ORDER BY spine_value
    )
    SELECT
        unique_key 
        ,spine_value AS dim_valid_from
        ,LEAD(spine_value, 1) OVER (PARTITION BY unique_key ORDER BY dim_valid_from) AS dim_valid_to
    FROM
        ordered_spine
    QUALIFY dim_valid_to IS NOT NULL
{%- endmacro -%}