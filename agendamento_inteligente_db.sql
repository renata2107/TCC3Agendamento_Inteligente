-- ==============================================================
-- BANCO: agendamento_inteligente_db
-- SGBD:  PostgreSQL 15+
-- Autor: Renata Lima Ferreira Ribeiro
-- TCC   – Sistema Web para Agendamento Inteligente
-- ==============================================================

-- PASSO 1: Criar o banco (execute separado no psql)
-- CREATE DATABASE agendamento_inteligente_db;
-- \c agendamento_inteligente_db

-- PASSO 2: Extensões obrigatórias
CREATE EXTENSION IF NOT EXISTS "pgcrypto";    -- para gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "btree_gist";  -- OBRIGATÓRIO para EXCLUDE USING GIST com UUID

-- ==============================================================
-- TABELA BASE: usuario
-- Classe pai da hierarquia (herança table-per-class)
-- ==============================================================
CREATE TABLE usuario (
    id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    nome          VARCHAR(150) NOT NULL,
    email         VARCHAR(150) NOT NULL UNIQUE,
    senha_hash    VARCHAR(255) NOT NULL,
    perfil        VARCHAR(20)  NOT NULL
                      CHECK (perfil IN ('cliente', 'profissional', 'admin')),
    ativo         BOOLEAN      NOT NULL DEFAULT TRUE,
    criado_em     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    atualizado_em TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ==============================================================
-- HERANÇA: cliente
-- ==============================================================
CREATE TABLE cliente (
    id_usuario       UUID PRIMARY KEY
                         REFERENCES usuario(id) ON DELETE CASCADE,
    cpf              CHAR(11)     UNIQUE,
    telefone         VARCHAR(20),
    data_nascimento  DATE,
    endereco         VARCHAR(255),
    lgpd_aceite      BOOLEAN      NOT NULL DEFAULT FALSE,
    lgpd_data_aceite TIMESTAMPTZ
);

-- ==============================================================
-- HERANÇA: profissional
-- Nota: aceita_agendamentos é distinto de usuario.ativo
--   usuario.ativo     → conta ativa no sistema
--   aceita_agendamentos → disponível para novos horários
-- ==============================================================
CREATE TABLE profissional (
    id_usuario          UUID PRIMARY KEY
                            REFERENCES usuario(id) ON DELETE CASCADE,
    cpf                 CHAR(11)     UNIQUE,
    especialidade       VARCHAR(100) NOT NULL,
    telefone            VARCHAR(20),
    disponibilidade     JSONB,
    aceita_agendamentos BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ==============================================================
-- HERANÇA: administrador
-- ==============================================================
CREATE TABLE administrador (
    id_usuario   UUID PRIMARY KEY
                     REFERENCES usuario(id) ON DELETE CASCADE,
    nivel_acesso VARCHAR(50) NOT NULL DEFAULT 'padrao'
);

-- ==============================================================
-- TABELA: servico
-- ==============================================================
CREATE TABLE servico (
    id          UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
    nome        VARCHAR(100)   NOT NULL,
    descricao   TEXT,
    duracao_min INTEGER        NOT NULL CHECK (duracao_min > 0),
    valor       NUMERIC(10, 2) NOT NULL CHECK (valor >= 0),
    ativo       BOOLEAN        NOT NULL DEFAULT TRUE,
    criado_em   TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- ==============================================================
-- TABELA ASSOCIATIVA: profissional_servico  (N:M)
-- Representa quais serviços cada profissional oferece.
-- PK composta: (id_profissional, id_servico)
-- criado_em permite auditoria temporal do vínculo
-- ==============================================================
CREATE TABLE profissional_servico (
    id_profissional UUID        NOT NULL
                        REFERENCES profissional(id_usuario) ON DELETE CASCADE,
    id_servico      UUID        NOT NULL
                        REFERENCES servico(id) ON DELETE CASCADE,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id_profissional, id_servico)
);

-- ==============================================================
-- TABELA CENTRAL: agendamento
--
-- CONSTRAINT chk_horario_valido:
--   Garante que data_hora_fim > data_hora (fim após início)
--
-- CONSTRAINT sem_conflito_profissional (EXCLUDE USING GIST):
--   Impede que um profissional tenha dois agendamentos
--   com sobreposição de horário.
--   O WHERE exclui cancelados e no_shows:
--   → sem esse filtro, um agendamento cancelado bloquearia
--     o horário permanentemente (bug crítico de negócio).
-- ==============================================================
CREATE TABLE agendamento (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_cliente      UUID        NOT NULL REFERENCES cliente(id_usuario),
    id_profissional UUID        NOT NULL REFERENCES profissional(id_usuario),
    id_servico      UUID        NOT NULL REFERENCES servico(id),
    data_hora       TIMESTAMPTZ NOT NULL,
    data_hora_fim   TIMESTAMPTZ NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'pendente'
                        CHECK (status IN (
                            'pendente',
                            'confirmado',
                            'cancelado',
                            'concluido',
                            'no_show'
                        )),
    observacao      TEXT,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    atualizado_em   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_horario_valido
        CHECK (data_hora_fim > data_hora),

    CONSTRAINT sem_conflito_profissional EXCLUDE USING gist (
        id_profissional                          WITH =,
        tstzrange(data_hora, data_hora_fim, '[)') WITH &&
    ) WHERE (status NOT IN ('cancelado', 'no_show'))
);

-- ==============================================================
-- TABELA: notificacao
-- ==============================================================
CREATE TABLE notificacao (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_agendamento UUID        NOT NULL
                       REFERENCES agendamento(id) ON DELETE CASCADE,
    canal          VARCHAR(20) NOT NULL
                       CHECK (canal IN ('email', 'sms', 'whatsapp', 'sistema')),
    mensagem       TEXT        NOT NULL,
    data_envio     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    enviado        BOOLEAN     NOT NULL DEFAULT FALSE,
    erro           TEXT
);

-- ==============================================================
-- TABELA: avaliacao
-- Relação 1:1 com agendamento — garantida pelo UNIQUE em id_agendamento
-- ==============================================================
CREATE TABLE avaliacao (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_agendamento UUID        NOT NULL UNIQUE
                       REFERENCES agendamento(id) ON DELETE CASCADE,
    nota           SMALLINT    NOT NULL CHECK (nota BETWEEN 1 AND 5),
    comentario     TEXT,
    data           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ==============================================================
-- TABELA: relatorio
-- ==============================================================
CREATE TABLE relatorio (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_admin       UUID        NOT NULL
                       REFERENCES administrador(id_usuario),
    tipo           VARCHAR(30) NOT NULL
                       CHECK (tipo IN ('ocupacao', 'cancelamentos', 'produtividade')),
    periodo_inicio DATE        NOT NULL,
    periodo_fim    DATE        NOT NULL,
    dados          JSONB,
    gerado_em      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ==============================================================
-- ÍNDICES DE PERFORMANCE  (RNF02: resposta < 2 segundos)
-- ==============================================================

-- Agendamentos por cliente (histórico, listagem)
CREATE INDEX idx_agendamento_cliente
    ON agendamento(id_cliente);

-- Agendamentos por profissional (agenda, relatórios)
CREATE INDEX idx_agendamento_profissional
    ON agendamento(id_profissional);

-- Agendamentos por data (busca de disponibilidade)
CREATE INDEX idx_agendamento_data_hora
    ON agendamento(data_hora);

-- Filtro por status (pendente, confirmado, etc.)
CREATE INDEX idx_agendamento_status
    ON agendamento(status);

-- Índice PARCIAL: notificações pendentes
-- Só indexa linhas onde enviado = FALSE → menor e mais rápido.
-- Notificações já entregues não ocupam espaço no índice.
CREATE INDEX idx_notificacao_pendente
    ON notificacao(data_envio)
    WHERE enviado = FALSE;

-- ==============================================================
-- TRIGGER: atualiza atualizado_em automaticamente
-- ==============================================================
CREATE OR REPLACE FUNCTION fn_atualizar_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.atualizado_em = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_usuario_ts
    BEFORE UPDATE ON usuario
    FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

CREATE TRIGGER trg_agendamento_ts
    BEFORE UPDATE ON agendamento
    FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- ==============================================================
-- DADOS DE EXEMPLO (opcional — remova em produção)
--
-- ATENÇÃO (segurança): nunca versione senhas neste script.
-- O administrador inicial deve ser criado manualmente, com uma
-- senha forte informada em tempo de execução, por exemplo:
--
--   psql -v senha_admin="$SENHA_ADMIN" \
--        -v email_admin="$EMAIL_ADMIN" \
--        -f criar_admin.sql agendamento_inteligente_db
--
-- onde criar_admin.sql contém:
--
--   INSERT INTO usuario (nome, email, senha_hash, perfil)
--   VALUES ('Admin Sistema', :'email_admin',
--           crypt(:'senha_admin', gen_salt('bf', 12)), 'admin');
--
--   INSERT INTO administrador (id_usuario, nivel_acesso)
--   SELECT id, 'super' FROM usuario WHERE email = :'email_admin';
-- ==============================================================

-- Serviços de exemplo
INSERT INTO servico (nome, descricao, duracao_min, valor)
VALUES
    ('Consulta Geral',     'Consulta médica geral',     30, 150.00),
    ('Retorno',            'Consulta de retorno',        20,  80.00),
    ('Exame Dermatológico','Avaliação da pele',          45, 200.00);

-- ==============================================================
-- FIM DO SCRIPT
-- Banco: agendamento_inteligente_db | PostgreSQL 15+
-- ==============================================================
