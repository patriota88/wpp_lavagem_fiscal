fx_version 'cerulean'
game 'gta5'

lua54 'yes'

name 'wpp_lavagem_fiscal'
author 'Patriota_88'
description 'Sistema de lavagem de dinheiro fiscal com empresas de fachada e interface de tablet (NUI).'
version '1.0.0'

-- Dependências obrigatórias
dependencies {
    'ox_lib',
    'oxmysql',
    'ox_inventory'
}

-- Arquivo de configuração (Carrega em AMBOS os lados primeiro)
shared_scripts {
    '@ox_lib/init.lua', -- Adicione esta linha aqui
    'config.lua'
}

-- Lado do Cliente
client_script 'client/main.lua'

-- Lado do Servidor (Na ordem correta de dependência)
server_scripts {
    '@oxmysql/lib/MySQL.lua', -- <--- ISSO É VITAL
    'server/database.lua',
    'server/main.lua',
    'server/accounting.lua'
}

-- Interface (NUI)
ui_page 'web/index.html'

files {
    'web/index.html',
    'web/style.css',
    'web/script.js'
}