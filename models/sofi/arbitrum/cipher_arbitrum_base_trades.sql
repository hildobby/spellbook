{{ config(
    schema = 'cipher_arbitrum',
    tags = ['dunesql'],
    alias = alias('base_trades')
    )
}}

{% set cipher_fan_start_date = '2023-09-20' %}

SELECT 'arbitrum' AS blockchain
, evt_block_time AS block_time
, evt_block_number AS block_number
, 'cipher' AS project
, trader
, subject
, CASE WHEN isBuy = TRUE THEN 'buy' ELSE 'sell' END AS trade_side
, ethAmount/1e18 AS amount_original
, coreAmount AS share_amount
, subjectEthAmount/1e18 AS subject_fee_amount
, protocolEthAmount/1e18 AS protocol_fee_amount
, 0x0000000000000000000000000000000000000000 AS currency_contract
, 'ETH' AS currency_symbol
, supply
, evt_tx_hash AS tx_hash
, evt_index
, contract_address
FROM {{source('cipher_arbitrum', 'Cipher_evt_Trade')}}
{% if is_incremental() %}
WHERE evt_block_time >= date_trunc('day', now() - interval '7' day)
{% else %}
WHERE evt_block_time >= TIMESTAMP '{{friend_tech_start_date}}'
{% endif %}