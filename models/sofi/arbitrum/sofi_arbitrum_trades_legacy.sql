{{ config(
    schema = 'sofi_arbitrum',
    tags = ['legacy', 'static'],
    alias = alias('trades', legacy_model=True)
    )
}}

SELECT 1