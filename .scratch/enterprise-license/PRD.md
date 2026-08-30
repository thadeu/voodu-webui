# Enterprise licensing

Status: done

> **Entregue, fases 1–4.** 841 testes verdes, rubocop e brakeman limpos, poller
> Go compilando e com os testes dele passando.
>
> **Dois desvios do plano, ambos deliberados:**
>
> 1. **Postgres é sinalizado, não bloqueado.** Bloquear exigiria verificar a
>    licença em `config/boot.rb`, antes do Rails carregar, reimplementando JWT
>    em Ruby puro — e seria trivialmente burlável por quem controla a imagem,
>    enquanto poderia falhar contra um cliente legítimo cujo arquivo de licença
>    não montou. O app avisa no boot e na UI; a cláusula da ELv2 é o que
>    respalda. A decisão nº 5 (nunca revogar) já apontava para cá.
>
> 2. **Retenção virou dois números, e o plano falava de um.** `keep_days`
>    (`VOODU_RETENTION_DAYS`, do operador, nunca da licença) e `serve_days`
>    (limitado pela licença). Sem essa separação, uma licença vencida encolheria
>    a janela que o sweeper honra e **apagaria o histórico do cliente** — a
>    armadilha nº 1 do próprio plano. O custo é que um cliente Enterprise
>    precisa setar `VOODU_RETENTION_DAYS=90` além de ter a licença; comprar o
>    entitlement não passa a consumir o disco dele em silêncio.
>
> Continua em aberto: duração da tolerância (30d é chute informado), onde fica o
> registro de quem comprou, e se a retenção Enterprise é por-servidor ou global.


## Context

voodu-webui ships one image in two shapes. Today both are free and identical in
capability: the licence adopted in v0.1.15 (Elastic License 2.0) forbids
offering the product as a hosted service and forbids circumventing licence-key
functionality — but **no licence-key functionality exists**. The clause protects
a mechanism that was never built, and there is nothing to sell.

This adds it. The goal is not to restrict the free install; it is to make one
paid capability real, with a mechanism that cannot brick a customer's
production.

The self-hosted free shape stays a complete product: `docker run`, no env vars,
one operator behind a VPN. That is the shape most people will use and it must
not get worse.

## Decisões travadas

| # | Decisão | Porquê |
|---|---|---|
| 1 | **Validação offline**, token assinado. Sem chamada de rede. | O segmento que compra é o de rede fechada. Phone-home quebra em air-gapped, coloca nosso uptime dentro do risco do cliente, e é o primeiro apontamento da revisão de segurança dele. |
| 2 | **RS256 com a gem `jwt` já presente** (2.10.3, via clowk). | Zero dependência nova, e o repo já verifica JWT RS256 no caminho do Clowk — mesmo idioma, mesma superfície de crypto. EdDSA exigiria `rbnacl` + libsodium na imagem por ganho marginal. |
| 3 | **O poller nunca é bloqueado.** | Coleta é o produto. Licença vencida que para de coletar não degrada, cega a operação no meio de um incidente. Alavanca comercial só onde o dano é reversível. |
| 4 | **Vencer nunca apaga dado.** | `LogTailCleanupJob:43` faz `File.delete`. Entitlement lido por esse job significa destruir histórico de cliente na expiração. |
| 5 | **Postgres nunca é revogado** depois de em uso. | Não existe "voltar para SQLite": os dados estão lá. Revogar tira o cliente do próprio banco. |
| 6 | **Emissão por CLI**, não por app. | Construir um SaaS de licenciamento antes da primeira venda é trabalho prematuro. Um script + um registro versionado bastam. |

## As três regras de segurança, ditas uma vez

Vencer a licença muda **o que pode ser criado** e **o que é servido**. Nunca
muda o que existe. Concretamente:

- **Nunca deleta.** Retenção menor esconde, não varre.
- **Nunca desconecta.** Postgres em uso continua em uso.
- **Nunca cega.** O poller coleta igual, com ou sem licença.

Se uma implementação futura precisar violar uma dessas, ela está errada.

## O formato

Um JWT RS256. A chave **pública** vai embutida no repo; a **privada** nunca
entra aqui — vive na infra do Thadeu e assina fora deste código.

```
VOODU_LICENSE=eyJhbGciOiJSUzI1NiJ9...
```

Claims:

| claim | exemplo | nota |
|---|---|---|
| `sub` | `acme-corp` | quem comprou; aparece na tela de settings |
| `exp` | unix ts | vencimento |
| `iat` | unix ts | emissão |
| `ent` | `{orgs: null, retention_days: 90, postgres: true}` | entitlements; `null` = sem limite |

Também aceito via `VOODU_LICENSE_FILE=/rails/storage/license.jwt`, para quem
prefere segredo em arquivo a segredo em env. Env tem precedência.

**Um token inválido, expirado ou ausente nunca levanta.** Ele resolve para os
limites OSS, e a razão fica visível na tela de settings. Uma licença que derruba
o boot é a decisão nº 3 pela porta dos fundos.

## Entitlements

No molde do `Permissions` (`app/models/permissions.rb`): uma tabela, defaults
explícitos, e nada fora dela é permitido.

| capacidade | OSS (default) | Enterprise |
|---|---|---|
| accounts | 1 | ilimitado |
| orgs | 1 | ilimitado |
| convites de membro | 0 | ilimitado |
| retenção | 3 dias | configurável, **default 90** |
| `DATABASE_URL` | ignorado com aviso | honrado |

**"Ilimitado" não vale para retenção, e isso é uma correção deliberada ao
pedido original.** A warehouse é SQLite num volume; retenção infinita é disco
cheio, e disco cheio derruba o container. Enterprise recebe um número
configurável com default de 90 dias, não infinito. Vender "unlimited" e entregar
um container morto em seis meses é pior que vender 90 dias.

Nota sobre as duas primeiras linhas: o **modo anônimo já provisiona exatamente
uma account e uma org** (`user.rb:107`) e já esconde convites. Ou seja, os
limites OSS são o comportamento atual da forma livre — eles só passam a morder
quando alguém liga `CLOWK_ENABLED=1` sem licença, que é exatamente a fronteira
que queremos cobrar.

## Mapa de arquivos

| arquivo | papel |
|---|---|
| `app/models/license.rb` | **novo** — verifica o JWT, devolve claims ou nulo-seguro. Nunca levanta. |
| `app/models/entitlements.rb` | **novo** — a tabela acima. Único lugar que responde "isto é permitido aqui". |
| `config/initializers/license.rb` | **novo** — resolve uma vez no boot para `config.x.license`, como o `clowk_enabled` |
| `lib/tasks/license.rake` | **novo** — `rake license:issue[sub,days]` assina com a chave privada apontada por env |
| `app/controllers/orgs_controller.rb:81` | recusa criar org além do limite |
| `app/controllers/onboardings_controller.rb:34` | idem, no primeiro workspace |
| convite de membro (Org::MembershipsController) | recusa além do limite |
| `app/services/log_search_data.rb:59` | janela servida passa a vir do entitlement |
| `gems/poller/lib/puma/plugin/poller.rb:33` | passa `POLLER_RETENTION_DAYS` no hash do `spawn` |
| `gems/poller/src/` | lê a env nova; **não sabe o que é licença**, recebe um número |
| `app/views/settings/index.rb` | linhas de licença: cliente, vencimento, o que está liberado |
| `config/initializers/clowk.rb` | `CLOWK_ENABLED=1` sem licença → avisa e segue em anônimo |

O poller receber um número em vez de um token é o que mantém o enforcement
inteiro em Ruby, num lugar só, em vez de espalhado por duas linguagens.

## Armadilhas, e a trava de cada uma

| armadilha | trava |
|---|---|
| Licença vencida apaga histórico | `LogTailCleanupJob` **não** lê entitlement. Retenção servida ≠ retenção varrida. Teste que pina isso. |
| Licença vencida derruba boot em Postgres | Decisão nº 5, e um teste que sobe com `DATABASE_URL` + licença expirada esperando sucesso. |
| Relógio errado no servidor do cliente reprova a licença | Tolerância de relógio no `exp` (leeway), e a razão da recusa visível em settings em vez de silêncio. |
| Chave privada vazar para o repo | Ela nunca entra. A rake task lê de env; teste de arquitetura proíbe `PRIVATE KEY` em qualquer arquivo versionado. |
| Alguém troca a chave pública embutida e emite a própria | Não há defesa técnica contra quem controla a imagem — é o que a cláusula da ELv2 cobre. Não vale ofuscar; vale registrar que o controle é jurídico. |
| Enforcement duplicado divergindo entre UI e endpoint | Botão escondido não é autorização. Toda checagem passa por `Entitlements`, e a UI lê o mesmo objeto. |
| Vencimento surpreende o operador | Tolerância de 30 dias com aviso escalando na UI, e o vencimento sempre visível em settings — não só quando já venceu. |

## Fases

Cada uma deixa a suíte verde e o `docker run` livre intocado.

**1 — Verificação e entitlements.** `License`, `Entitlements`, o initializer, a
rake task de emissão, e a tela de settings mostrando o estado. **Nada é
bloqueado ainda** — esta fase só torna a licença legível e visível. Dá para
emitir e instalar uma licença real antes de qualquer regra existir, que é a
ordem certa para não descobrir o formato errado com enforcement já espalhado.

**2 — Limites que degradam com segurança.** Orgs, accounts, convites. São os
três onde recusar criação não desfaz nada.

**3 — Retenção.** Janela servida no Rails, `POLLER_RETENTION_DAYS` no spawn, a
env nova no Go. A fase com a armadilha nº 1; entra com o teste de que o cleanup
não olha para a licença.

**4 — Postgres e tolerância.** `DATABASE_URL` honrado só com licença **na
primeira ativação**, tolerância de 30 dias, avisos escalando. Última porque
depende de todas as anteriores estarem calibradas.

## O que NÃO fazer

- **Não bloquear o poller.** Decisão nº 3.
- **Não construir app de licenciamento**, nem endpoint de validação, nem
  telemetria de uso. Se um dia houver clientes suficientes para justificar,
  a decisão nº 1 continua valendo: emissão pode virar app, validação não.
- **Não fazer a licença levantar exceção** em nenhum caminho. Ausente,
  malformada e expirada são estados normais com resposta definida.
- **Não vender "unlimited retention".** Ver a nota na tabela.
- **Não ofuscar a verificação.** Quem controla a imagem sempre poderá alterá-la;
  gastar esforço ali compra nada e complica o código que precisa ser auditável.
- **Não gatilhar em cima de `Permissions`.** São eixos diferentes: papel é quem
  você é dentro da org, entitlement é o que este deploy comprou. Misturá-los
  torna os dois ilegíveis.

## Verificação

```sh
bin/rails test && bin/rubocop && bin/brakeman --no-pager
bin/bundler-audit                                   # antes de tag, não no CI
DATABASE_URL=postgres://…/voodu bin/rails test      # sem perna no CI
```

Ponta a ponta, com uma licença emitida de verdade pela rake task:

1. `docker run` sem `VOODU_LICENSE` → sobe, uma org, sem convites, retenção 3d
2. mesma imagem com licença válida → segunda org criável, convite aparece
3. licença **expirada** com `DATABASE_URL` → **continua servindo**, aviso na UI,
   segunda org recusada
4. licença expirada e volta no tempo do cleanup → histórico **intacto**

O caso 3 é o que separa este desenho de um que derruba produção de cliente. Se
ele falhar, nada mais importa.

## Em aberto

- Duração da tolerância: 30 dias é chute informado, não decisão.
- Onde fica o registro de quem comprou (arquivo versionado? repo privado?).
- Se a retenção Enterprise default (90d) deve ser por-servidor ou global.
