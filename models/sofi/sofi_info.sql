{{ config(
        tags = ['dunesql', 'static'],
        schema='sofi',
        alias = alias('info'),
        post_hook='{{ expose_spells(\'["bnb", "avalanche_c", "arbitrum", "base"]\',
                                    "sector",
                                    "sofi",
                                    \'["hildobby"]\') }}')
}}

SELECT project, name, blockchain, share_name, x_username
FROM (VALUES
        ('friend_tech', 'friend.tech', 'base', 'share', 'friendtech')
    	, ('post_tech', 'post.tech', 'arbitrum', 'share', 'PostTechSoFi')
    	, ('stars_arena', 'Stars Arena', 'avalanche_c', '', 'starsarenacom')
    	, ('cipher', 'cipher.fan', 'arbitrum', 'core', 'cipher_cores')
    	, ('friend3', 'Friend3', 'bnb', 'ticket', 'Friend3AI')
        , ('hub3', 'hub3', 'solana', '', 'hub3ee')
        , ('friendzy', 'Friendzy', 'solana', '', 'Friendzygg_')
    ) AS temp_table (project, name, blockchain, share_name, x_username)