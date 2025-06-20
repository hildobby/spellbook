{{
    config(
        schema = 'uniswap_v2_base',
        alias = 'base_trades',
        materialized = 'incremental',
        file_format = 'delta',
        incremental_strategy = 'merge',
        unique_key = ['tx_hash', 'evt_index'],
        incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.block_time')]
    )
}}
--stamp 1
{{
    uniswap_compatible_v2_trades(
        blockchain = 'base',
        project = 'uniswap',
        version = '2',
        Pair_evt_Swap = source('uniswap_v2_base', 'UniswapV2Pair_evt_Swap'),
        Factory_evt_PairCreated = source('uniswap_v2_base', 'UniswapV2Factory_evt_PairCreated')
    )
}}