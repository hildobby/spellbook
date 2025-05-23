{{ config(
    schema='lido_liquidity_optimism',
    alias = 'solidly_pools',
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['pool', 'time'],
    incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.time')],
    post_hook='{{ expose_spells(blockchains = \'["optimism"]\',
                                spell_type = "project",
                                spell_name = "lido_liquidity",
                                contributors = \'["pipistrella"]\') }}'
    )
}}

{% set project_start_date = '2024-01-30' %}

with pools AS (
    SELECT
      pool AS address,
      'optimism' AS blockchain,
      'solidly' AS project,
      cast(fee as double) / CAST(10000 AS DOUBLE) AS fee,
      token0, token1
    FROM
      {{source('solidly_v3_optimism','solidlyv3factory_evt_poolcreated')}}
    WHERE
      token0 = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb
      OR token1 = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb
  )


 , tokens AS (
    SELECT DISTINCT
      token AS address
    FROM
      (
        SELECT token1 AS token
        FROM {{source('solidly_v3_optimism','solidlyv3factory_evt_poolcreated')}}
        WHERE token0 = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb
        UNION
        SELECT token0
        FROM {{source('solidly_v3_optimism','solidlyv3factory_evt_poolcreated')}}
        WHERE token1 = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb
        UNION
        SELECT  0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb
      ) AS t

  )

 , tokens_prices_daily AS (
    SELECT DISTINCT
      DATE_TRUNC('day', minute) AS time,
      contract_address  AS token,
      decimals,
      symbol,
      AVG(price) AS price
    FROM
      {{source('prices','usd')}} p

    {% if not is_incremental() %}
    WHERE DATE_TRUNC('day', p.minute) >= DATE '{{ project_start_date }}'
    {% else %}
    WHERE {{ incremental_predicate('p.minute') }}
    {% endif %}
    AND DATE_TRUNC('day', minute) < current_date
    AND blockchain = 'optimism'
    AND contract_address IN (SELECT address  FROM tokens      )
    GROUP BY 1, 2,3,4
    UNION ALL
    SELECT DISTINCT
      DATE_TRUNC('day', minute),
      contract_address  AS token,
      decimals,
      symbol,
      LAST_VALUE(price) OVER (
        PARTITION BY
          DATE_TRUNC('day', minute),
          contract_address
        ORDER BY
          minute NULLS FIRST range BETWEEN UNBOUNDED preceding
          AND UNBOUNDED following
      ) AS price
    FROM
      {{source('prices','usd')}}
    WHERE
      DATE_TRUNC('day', minute) = current_date
      AND blockchain = 'optimism'
      AND contract_address IN (SELECT address  FROM tokens      )
  ),

  tokens_prices_hourly AS (
        SELECT DISTINCT
          DATE_TRUNC('hour', minute) AS time,
          LEAD(DATE_TRUNC('hour', minute),1,DATE_TRUNC('hour', NOW() + INTERVAL '1' hour)) OVER (PARTITION BY contract_address  ORDER BY DATE_TRUNC('hour', minute) NULLS FIRST) AS next_time,
          contract_address  AS token,
          decimals,
          symbol,
          LAST_VALUE(price) OVER (
            PARTITION BY
              DATE_TRUNC('hour', minute),
              contract_address
            ORDER BY
              minute NULLS FIRST range BETWEEN UNBOUNDED preceding
              AND UNBOUNDED following
          ) AS price
        FROM
          {{source('prices','usd')}} p
        {% if not is_incremental() %}
        WHERE DATE_TRUNC('day', p.minute) >= DATE '{{ project_start_date }}'
        {% else %}
        WHERE {{ incremental_predicate('p.minute') }}
        {% endif %}
        AND blockchain = 'optimism'
        AND contract_address IN (SELECT address FROM tokens)

  )

  , swap_events AS (
    SELECT
      DATE_TRUNC('day', sw.evt_block_time) AS time,
      sw.contract_address AS pool,
      cr.token0,
      cr.token1,
      SUM(CAST(amount0 AS DOUBLE)) AS amount0,
      SUM(CAST(amount1 AS DOUBLE)) AS amount1
    FROM
      {{source('solidly_v3_optimism','solidlyv3pool_evt_swap')}} AS sw
      LEFT JOIN {{source('solidly_v3_optimism','solidlyv3factory_evt_poolcreated')}} AS cr ON sw.contract_address = cr.pool
    {% if not is_incremental() %}
    WHERE DATE_TRUNC('day', sw.evt_block_time) >= DATE '{{ project_start_date }}'
    {% else %}
    WHERE {{ incremental_predicate('sw.evt_block_time') }}
    {% endif %}
    and sw.contract_address IN (SELECT address FROM pools)
    GROUP BY 1, 2, 3, 4
  )

  , mint_events AS (
    SELECT
      DATE_TRUNC('day', mt.evt_block_time) AS time,
      mt.contract_address AS pool,
      cr.token0,
      cr.token1,
      SUM(CAST(amount0 AS DOUBLE)) AS amount0,
      SUM(CAST(amount1 AS DOUBLE)) AS amount1
    FROM
      {{source('solidly_v3_optimism','solidlyv3pool_evt_mint')}} AS mt
      LEFT JOIN {{source('solidly_v3_optimism','solidlyv3factory_evt_poolcreated')}} AS cr ON mt.contract_address = cr.pool
    {% if not is_incremental() %}
    WHERE DATE_TRUNC('day', mt.evt_block_time) >= DATE '{{ project_start_date }}'
    {% else %}
    WHERE {{ incremental_predicate('mt.evt_block_time') }}
    {% endif %}
      and mt.contract_address IN (SELECT address FROM pools)
    GROUP BY 1, 2, 3, 4

  )

  , burn_events AS (
    SELECT
      c.evt_block_time AS time,
      c.contract_address AS pool,
      cr.token0,
      cr.token1,
      (-1) * CAST(amount0 AS DOUBLE) AS amount0,
      (-1) * CAST(amount1 AS DOUBLE) AS amount1,
      c.evt_tx_hash
    FROM
      {{source('solidly_v3_optimism','solidlyv3pool_evt_burn')}} AS c
      LEFT JOIN {{source('solidly_v3_optimism','solidlyv3factory_evt_poolcreated')}} AS cr ON c.contract_address = cr.pool
    {% if not is_incremental() %}
    WHERE DATE_TRUNC('day', c.evt_block_time) >= DATE '{{ project_start_date }}'
    {% else %}
    WHERE {{ incremental_predicate('c.evt_block_time') }}
    {% endif %}
    and c.contract_address IN (SELECT address FROM pools)
  )


  , daily_delta_balance AS (

    SELECT
      time,
      pool,
      token0,
      token1,
      SUM(COALESCE(amount0, 0)) AS amount0,
      SUM(COALESCE(amount1, 0)) AS amount1
    FROM
      (
        SELECT
          time,
          pool,
          token0,
          token1,
          amount0,
          amount1
        FROM swap_events
        UNION ALL
        SELECT
          time,
          pool,
          token0,
          token1,
          amount0,
          amount1
        FROM mint_events
      UNION ALL
        SELECT
          DATE_TRUNC('day', time),
          pool,
          token0,
          token1,
          SUM(amount0),
          SUM(amount1)
        FROM burn_events
        GROUP BY 1, 2, 3, 4
      ) AS balance
    GROUP BY 1, 2, 3, 4

  )

  , pool_liquidity AS (
    SELECT
      time,
      pool,
      d.token0,
      d.token1,
      SUM(amount0)  AS amount0,
      SUM(amount1)  AS amount1
    FROM daily_delta_balance d
    GROUP BY 1,2,3,4
  )

  , swap_events_hourly AS (
        SELECT
          sw.evt_block_time as time,
          sw.contract_address AS pool,
          token0,
          token1,
          COALESCE(SUM(CAST(ABS(amount0) AS DOUBLE)), 0) AS amount0,
          COALESCE(SUM(CAST(ABS(amount1) AS DOUBLE)), 0) AS amount1
        FROM
          {{source('solidly_v3_optimism','solidlyv3pool_evt_swap')}} AS sw
          inner join pools on sw.contract_address = pools.address

        {% if not is_incremental() %}
        WHERE DATE_TRUNC('day', sw.evt_block_time) >= DATE '{{ project_start_date }}'
        {% else %}
        WHERE {{ incremental_predicate('sw.evt_block_time') }}
        {% endif %}

        GROUP BY 1, 2, 3, 4

  )


  , trading_volume AS (
    SELECT
      date_trunc('day', s.time)  AS time,
      pool,
      sum(COALESCE((p.price * amount0) / CAST(POWER(10, p.decimals) AS DOUBLE),0)) AS volume
    FROM
      swap_events_hourly AS s
      LEFT JOIN tokens_prices_hourly AS p ON date_trunc('hour', s.time) >= p.time
      AND date_trunc('hour', s.time) < p.next_time
      AND s.token0 = p.token
    group by 1,2
  )

  , all_metrics AS (
    SELECT
      l.pool,
      pools.blockchain,
      pools.project,
      pools.fee,
      cast(l.time as date) as time,
      CASE
        WHEN l.token0 = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb  THEN l.token0
        ELSE l.token1
      END AS main_token,
      coalesce(CASE
        WHEN l.token0 = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb  THEN p0.symbol
        ELSE p1.symbol
      END, 'wstETH') AS main_token_symbol,
      CASE
        WHEN l.token0 = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb  THEN l.token1
        ELSE l.token0
      END AS paired_token,
      CASE
        WHEN l.token0 = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb  THEN p1.symbol
        ELSE p0.symbol
      END AS paired_token_symbol,
      CASE
        WHEN l.token0 = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb  THEN amount0 / CAST(POWER(10, coalesce(p0.decimals,18)) AS DOUBLE)
        ELSE amount1 / CAST(POWER(10, coalesce(p1.decimals,18)) AS DOUBLE)
      END AS main_token_reserve,
      CASE
        WHEN l.token0 = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb  THEN amount1 / CAST(POWER(10, p1.decimals) AS DOUBLE)
        ELSE amount0 / CAST(POWER(10, p0.decimals) AS DOUBLE)
      END AS paired_token_reserve,
      CASE
        WHEN l.token0 = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb  THEN p0.price
        ELSE p1.price
      END AS main_token_usd_price,
      CASE
        WHEN l.token0 = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb  THEN p1.price
        ELSE p0.price
      END AS paired_token_usd_price,
      volume AS trading_volume
    FROM
      pool_liquidity AS l
      LEFT JOIN pools ON l.pool = pools.address
      LEFT JOIN tokens AS t0 ON l.token0 = t0.address
      LEFT JOIN tokens AS t1 ON l.token1 = t1.address
      LEFT JOIN tokens_prices_daily AS p0 ON l.time = p0.time   AND l.token0 = p0.token
      LEFT JOIN tokens_prices_daily AS p1 ON l.time = p1.time   AND l.token1 = p1.token
      LEFT JOIN trading_volume AS tv ON l.time = tv.time AND l.pool = tv.pool
  )
SELECT blockchain||' '||project||' ' ||COALESCE(paired_token_symbol, 'unknown')||':'||main_token_symbol||' '||format('%,.3f',round(coalesce(fee,0),4)) AS pool_name,
  *
FROM
  all_metrics

