# Deploy Gradual em EKS com Arquitetura em Shards

Cluster EKS com **EKS Auto Mode**, dois NodePools que funcionam como
**shards fisicamente isolados** (Spot, Bottlerocket, taint dedicado, máximo
aproximado de 3 EC2 cada), um repositório ECR, o **ArgoCD**, o **Argo
Rollouts** e o **Argo Workflows** instalados via Helm, e uma aplicação
Java/Spring Boot de exemplo cujo deploy é gradual em dois níveis:

- **Dentro de cada shard**: canário controlado pelo **Argo Rollouts**
  (`Rollout` em vez de `Deployment`, com passos de peso/pausa).
- **Entre as shards**: promovido por um único `ApplicationSet` do ArgoCD
  que gera as duas `Application` (uma por shard), e que só sincroniza a
  segunda shard depois de uma **aprovação manual**.

O disparo de tudo começa com uma mudança em `apps/`: um **Argo Workflow**
(disparado automaticamente por polling em até 2 min, veja "CI: Argo
Workflows" abaixo — ou manualmente, se não quiser esperar) builda a imagem,
dá push no ECR e atualiza `apps/springboot/values.yaml` no Git — é esse
commit que o ArgoCD detecta e sincroniza automaticamente na shard 1,
iniciando o canário.

## Como o projeto atende aos requisitos

| Requisito | Onde |
|---|---|
| Cada NodePool é uma shard fisicamente isolada | `terraform/platform/nodepools.tf` — taint `shard=<nome>:NoSchedule` + label, com toleration/nodeSelector correspondentes no `Rollout` (`apps/springboot/templates/rollout.yaml`) |
| App Java/Maven/Spring Boot | `apps/` (`pom.xml`, `src/main/java/...`) |
| Imagem publicada no ECR | `terraform/infra/ecr.tf` + `apps/Dockerfile` + `terraform/platform/argoworkflows-template.tf` (build+push automático) / `scripts/build-push.{sh,ps1}` (manual) |
| Nova imagem no ECR dispara o deploy no Kubernetes | `terraform/platform/argoworkflows-template.tf` atualiza `apps/springboot/values.yaml` e dá `git push` — a `Application` `springboot-shard-1` (`syncPolicy.automated`) sincroniza sozinha a partir daí |
| Deploy gradual dentro da shard = canário Argo Rollouts | `apps/springboot/templates/rollout.yaml` (`strategy.canary.steps`) |
| Deploy gradual entre shards = aprovação manual | `terraform/platform/argocd-applicationset.tf` — `syncPolicy.automated` só na `springboot-shard-1` |
| ApplicationSet do ArgoCD controla o deploy entre shards | `terraform/platform/argocd-applicationset.tf` — um único `ApplicationSet` (`springboot-shards`), com um generator `list` por shard |
| Toda a infra criada pelo candidato (EKS, EC2, app Java) | `terraform/infra` + `terraform/platform` + `apps/` |
| IaC | Terraform (`terraform/infra`, `terraform/platform`) |
| Uma região/uma conta AWS | `var.aws_region` único, sem multi-account/multi-region |
| Helm para empacotamento | `apps/springboot` (chart da app) + ArgoCD/Argo Rollouts/Argo Workflows instalados via `helm_release` |
| README com visão geral, como iniciar, provisionar e destruir | este arquivo |

## Decisões de arquitetura e alternativas consideradas

Ao longo do projeto, alguns pontos tinham mais de uma forma razoável de
resolver. A tabela abaixo registra as opções que foram apresentadas, qual
foi escolhida e por quê — para não parecer que a alternativa não foi
considerada, e para facilitar reverter caso o contexto mude (cada linha
aponta pro arquivo a mexer).

| Decisão | Opções consideradas | Escolhida | Por quê |
|---|---|---|---|
| Disparo do build (Argo Workflow) após `git push` | **(A)** Argo Events + webhook do GitHub — instantâneo, mas exige instalar mais componentes (`EventBus`/`EventSource`/`Sensor`) e expor um endpoint HTTP alcançável pelo GitHub pela internet. **(B)** `CronWorkflow` com polling (`git ls-remote` a cada 2 min). **(C)** Só manual (`argo submit`), sem nenhum disparo automático. | **(B) CronWorkflow com polling** — `terraform/platform/argoworkflows-poller.tf` | Não precisa expor nenhum endpoint novo à internet nem instalar componentes novos: é sempre o cluster puxando informação do GitHub (saída), nunca o GitHub entrando no cluster (entrada). Troca instantaneidade (que a opção A daria) por menos superfície de exposição — para uma Demo, o atraso de até 2 min é irrelevante. (C) foi descartada porque o objetivo explícito era eliminar o `argo submit` manual. |
| Promoção do canário dentro de cada shard (Argo Rollouts) | **(A)** `pause` com `duration` fixa (ex.: 60s) — promove sozinho depois do tempo, sem intervenção. **(B)** `pause: {}` (sem duration) — fica parado indefinidamente até `kubectl argo rollouts promote` manual. | **(B) Pausa indefinida / promoção manual** — `apps/springboot/values.yaml` (`canary.steps`) | Requisito explícito do usuário: nenhum canário deve promover sozinho depois de X segundos, nem dentro da shard nem entre shards — aprovação manual nos dois níveis. (A) foi a configuração inicial do projeto, trocada depois desse pedido. |
| Promoção entre shards (ArgoCD) | **(A)** `syncPolicy.automated` nas duas shards — pipeline totalmente automático fim a fim, sem clique manual entre shard 1 e shard 2. **(B)** `syncPolicy.automated` só na shard-1; shard-2 fica `OutOfSync` até `argocd app sync springboot-shard-2` manual. | **(B) Aprovação manual entre shards** — `terraform/platform/argocd-applicationset.tf` | É o requisito funcional original do desafio ("aprovação manual entre shards via ArgoCD"). (A) chegou a ser implementada e testada (a pedido do usuário, pra automatizar o pipeline fim a fim durante os testes), mas foi revertida depois que o usuário confirmou que o requisito de aprovação manual devia prevalecer. |
| Acesso à UI do Argo Workflows | **(A)** NLB `internal` — só acessível de dentro da VPC (bastion/VPN). **(B)** NLB `internet-facing` — acessível publicamente pela internet. | **(B) `internet-facing`** — `terraform/platform/environment/dev/argo-workflows.yaml` | Decisão explícita do usuário. Registrado como ponto de atenção no próprio arquivo de values e na seção "Expondo o Argo Workflows via LoadBalancer" abaixo: combinado com `--auth-mode=server` (UI sem login), isso dá controle real sobre o pipeline de CI a qualquer pessoa com o hostname do NLB — aceitável para Demo, não recomendado além disso. |
| Acesso web às apps rodando nas shards (para testar manualmente) | **(A)** Um NLB por shard, igual ArgoCD/Argo Workflows. **(B)** `kubectl port-forward` sob demanda. | **(A) Um NLB por shard** — `apps/springboot/templates/service-stable.yaml` | Decisão explícita do usuário para eliminar a necessidade de `port-forward`. Como o chart é o mesmo aplicado nas duas shards (só `shard`/`namespace` mudam via o ApplicationSet), essa única mudança já provisiona os dois NLBs — um por namespace de shard. Ver seção "Expondo as apps das shards via LoadBalancer" abaixo. `port-forward` continua documentado em `TESTE-END-TO-END.md` como alternativa/fallback (útil se o hostname do NLB ainda não tiver propagado). |
| Build da imagem em paralelo ("modo gráfico", inspirado num artigo sobre `withParam`) | **(A)** `withParam` pra buildar N imagens em paralelo (fan-out). **(B)** Manter os 4 passos sequenciais (`steps`) como estão. | **(B) Sequencial, sem paralelismo** | O projeto builda uma única imagem a partir de um único `Dockerfile` — não há múltiplos alvos de build pra paralelizar. `withParam` resolve fan-out sobre uma lista de itens distintos, o que não se aplica aqui. Além disso, qualquer `Workflow` do Argo já renderiza como grafo na UI — não existe um "modo gráfico" separado a habilitar. Descartada por ora ("por enquanto não"), fica registrado caso o projeto cresça pra buildar mais de uma imagem. |
| Estrutura do ApplicationSet (shard-1/shard-2) | **(A)** Dois `kubectl_manifest` fixos (dois recursos `ApplicationSet`, um por shard). **(B)** Um único `ApplicationSet`, com um generator `list` por shard (cada um com 1 elemento e, se precisar, seu próprio `template` override) em vez de um único generator com 2 elementos. | **(B) Um único `ApplicationSet`** — `terraform/platform/argocd-applicationset.tf` | O requisito pede "**um** ApplicationSet controlando o deploy entre as shards" — (A) tecnicamente usava o recurso certo (`kind: ApplicationSet`), mas eram **dois** objetos, não um. (B) usa um único `ApplicationSet`, com dois generators `list` (não um único generator com 2 elementos): o override de `template` no ArgoCD é por **generator**, não por elemento dentro da lista de um mesmo generator, então variar o `syncPolicy` por shard exige um generator por shard. O generator da shard-1 tem seu próprio `template` (cópia completa — `metadata`/`project`/`source`/`destination`/`syncPolicy`, exigida pelo schema do CRD assim que qualquer `template` de generator existe) sobrescrevendo o `syncPolicy` com `automated`; o da shard-2 não tem `template` nenhum, herdando o template top-level inteiro (sem `automated`) — mesmo resultado de aprovação manual de antes, agora com um único recurso. |

## Pré-requisitos

- Terraform >= 1.4.4
- AWS CLI configurado com credenciais válidas
- Helm >= 3.8 (usado internamente pelo provider `helm`)
- Permissões IAM para criar VPC, EKS, IAM Roles (incluindo um IAM OIDC
  Identity Provider para o cluster), ECR
- `kubectl` + [plugin do Argo Rollouts](https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation) (`kubectl argo rollouts`), útil para acompanhar o canário
- [ArgoCD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) (`argocd`), útil para dar a aprovação manual entre shards
- [Argo Workflows CLI](https://argo-workflows.readthedocs.io/en/latest/walk-through/argo-cli/) (`argo`), opcional — só necessário se quiser disparar/acompanhar o build+push manualmente em vez de esperar o `CronWorkflow` de polling (veja "CI: Argo Workflows" abaixo)
- Um Personal Access Token do GitHub (escopo `repo`) para o Argo Workflow conseguir dar `git push` de volta no repositório
- Maven e Docker (só para `scripts/build-push.*`, se quiser buildar a app manualmente, sem o Argo Workflow)

## Estrutura

```
terraform/
  infra/                  # Camada 1 — VPC, IAM, cluster EKS, ECR, logs
    versions.tf / providers.tf / variables.tf / locals.tf
    vpc.tf / iam.tf / eks.tf / logging.tf / ecr.tf / outputs.tf
    environment/dev/
      terraform.tfvars
      argocd.yaml
  platform/               # Camada 2 — NodeClasses, NodePools, ArgoCD, Rollouts, Workflows
    versions.tf / providers.tf / variables.tf / locals.tf
    nodeclasses.tf / nodepools.tf
    argocd.tf / argocd-github-secret.tf / argocd-project.tf / argocd-applicationset.tf
    argorollouts.tf
    argoworkflows.tf / argoworkflows-irsa.tf / argoworkflows-template.tf
    argoworkflows-poller.tf  # CronWorkflow: dispara o build sozinho via polling do Git
    environment/dev/       # cópia própria (independente da de infra/) — veja Notas
      terraform.tfvars
      secrets.tfvars.example   # copie para secrets.tfvars (gitignorado) e preencha
      argocd.yaml
      argo-workflows.yaml     # values do chart argo-workflows (UI via NLB)
apps/
  springboot/             # Helm chart da app (usado pelas DUAS shards)
    Chart.yaml / values.yaml
    templates/
      rollout.yaml         # argoproj.io/v1alpha1 Rollout, estratégia canary
      service-canary.yaml
      service-stable.yaml
  src/main/java/com/example/demo/
    Application.java        # bootstrap Spring Boot
    ApplicationController.java  # GET /, /health, /version (mostram shard + versão)
  src/main/resources/application.properties
  Dockerfile
  pom.xml
scripts/
  build-push.sh / build-push.ps1   # build (Maven) + push manual da imagem no ECR (alternativa ao Argo Workflow)
  02-get-argocd-lb-address-and-password.sh
```

- `versions.tf` — versões do Terraform e dos providers de cada camada
- `providers.tf` — configuração dos providers (`infra` só usa `aws`;
  `platform` usa `aws` (para autenticar no cluster e para o IRSA do Argo
  Workflow), mais `kubernetes`, `helm`, `kubectl` e `tls`)
- `variables.tf` — variáveis de entrada de cada camada
- `locals.tf` — cálculo do limite de CPU/memória usado para aproximar
  "máximo 3 nodes" por shard (duplicado nas duas camadas — veja abaixo)
- `vpc.tf` — VPC com subnets públicas e privadas (módulo oficial)
- `iam.tf` — roles do cluster e dos nodes com as políticas exigidas pelo Auto Mode
- `eks.tf` — recurso do cluster EKS com `compute_config.enabled = true`
- `logging.tf` — CloudWatch Log Group com retenção definida para os logs do control plane
- `ecr.tf` — repositório ECR + lifecycle policy
- `nodeclasses.tf` — NodeClass (`eks.amazonaws.com/v1`) dos shards 1 e 2
- `nodepools.tf` — NodePool (`karpenter.sh/v1`) dos shards 1 e 2: Spot/On-Demand + **taint `shard=<nome>:NoSchedule`** (isolamento físico)
- `argocd.tf` — instalação do ArgoCD via Helm (chart oficial `argo-cd` do repo `argo-helm`)
- `argocd-github-secret.tf` — Secret de credenciais do repositório GitHub para o **ArgoCD** clonar (**comentado**, veja Notas — diferente do Secret usado pelo Argo Workflow, veja abaixo)
- `argocd-project.tf` — AppProject do ArgoCD
- `argocd-applicationset.tf` — um único `ApplicationSet` (dois generators `list`, um por shard) gerando as duas `Application`, aprovação manual a partir da 2ª
- `argorollouts.tf` — instalação do Argo Rollouts via Helm (namespace `argo-rollouts`)
- `argoworkflows.tf` — instalação do Argo Workflows via Helm (namespace `argo-workflows`)
- `argoworkflows-irsa.tf` — IAM OIDC Identity Provider do cluster + role/policy IRSA (push no ECR) + ServiceAccount + Secret de credenciais Git
- `argoworkflows-template.tf` — `WorkflowTemplate` com os passos de build+push+atualização do Git
- `argoworkflows-poller.tf` — `CronWorkflow` que faz polling do Git a cada 2 min e dispara o `build-push-springboot` sozinho quando detecta um commit novo (dispensa `argo submit` manual)
- `outputs.tf` — endpoint, ARNs, URL do ECR e comando do kubectl (camada infra)

## Camadas do Terraform: `infra` e `platform`

O código é dividido em **dois root modules Terraform separados, com states
independentes**:

- **`terraform/infra`** — só usa o provider `aws`. Cria VPC, IAM, o cluster
  EKS (sem nenhum workload Kubernetes) e o ECR.
- **`terraform/platform`** — usa `aws` (para autenticar via
  `data "aws_eks_cluster"` / `data "aws_eks_cluster_auth"`, apontando para o
  cluster já criado por `infra`, e também para o IRSA do Argo Workflow) e os
  providers `kubernetes`, `helm`, `kubectl` e `tls`. Cria NodeClasses,
  NodePools (com o taint que isola cada shard), ArgoCD, o AppProject/
  ApplicationSet, o Argo Rollouts e o Argo Workflows.

Como `platform` sempre aplica **depois** que `infra` já criou o cluster (o
cluster é resolvido por nome via data source, não por referência direta ao
resource), não há problema de bootstrap — basta aplicar `infra`, depois
`platform`, nessa ordem, sempre, sem precisar de `-target`.

Cada camada tem seu **próprio** `environment/dev/` (não são mais
compartilhados) — se mudar uma variável que existe nos dois arquivos
(`shard_instance_types`, `shard_max_nodes`, `ecr_repository_name`),
replique em ambos:

- `terraform/infra/environment/dev/terraform.tfvars`
- `terraform/platform/environment/dev/terraform.tfvars`

Outras duplicações entre as camadas:

- `locals.tf` (o mapa `instance_specs` e o cálculo de `shard_vcpu_limit`/
  `shard_memory_limit`) existe nas duas camadas porque `nodepools.tf` (em
  `platform`) precisa dele. Hoje só é efetivamente **usado** em `platform`
  — em `infra` ficou como código morto depois da divisão (veja Notas).
- O nome da role dos nodes (`${var.cluster_name}-node-role`, criada em
  `infra/iam.tf`) é passado para `platform` via a variável `node_role_name`
  (`terraform.tfvars`), em vez de referenciar `aws_iam_role.node`
  diretamente (que só existe no state de `infra`).

## Isolamento físico das shards

Cada shard = um NodePool + um NodeClass (`terraform/platform/nodeclasses.tf`,
`nodepools.tf`), com:

- **Label** `shard: shard-1` / `shard: shard-2` no node — usado pelo
  `nodeSelector` do `Rollout`.
- **Taint** `shard=shard-1:NoSchedule` / `shard=shard-2:NoSchedule` — é isso
  que torna o isolamento **físico** de verdade: sem o taint, o
  `nodeSelector` garante que o pod da app vá para o node certo, mas não
  impede que OUTROS pods (sem esse nodeSelector) também caiam ali. Com o
  taint, só pods com a `toleration` correspondente conseguem agendar nesses
  nodes — e o `Rollout` (`apps/springboot/templates/rollout.yaml`) já
  declara essa toleration.
- **Capacity type:** Spot e On-Demand (`karpenter.sh/capacity-type: spot`/`on-demand`) — mais de uma opção reduz o risco de falha por falta de capacidade Spot.
- **AMI:** Bottlerocket — única opção no EKS Auto Mode (gerenciada pela
  AWS, não é configurável).
- **Instância:** conjunto de tipos equivalentes em `var.shard_instance_types`
  (ex.: `["m5.large", "m5a.large"]`) — mais de um tipo reduz o risco de
  falha por falta de capacidade de um tipo específico.
- **"Máximo 3 EC2":** o Karpenter/EKS Auto Mode **não tem um campo nativo
  de contagem máxima de nodes** — os limites de um NodePool são sempre por
  soma de recursos (`limits.cpu`/`limits.memory`). Para aproximar um teto
  de 3 instâncias, calculamos `limits.cpu`/`limits.memory` com base no
  **maior** tipo do conjunto em `var.shard_instance_types`, multiplicado
  por `var.shard_max_nodes` (`locals.tf`) — assim o teto nunca é
  ultrapassado, mesmo se o Karpenter só conseguir capacidade do tipo maior.
  Se adicionar um tipo novo à lista, inclua as specs dele em
  `local.instance_specs` **nos dois `locals.tf`**.

## Deploy gradual: canário (dentro da shard) + aprovação manual (entre shards)

### Dentro da shard: canário do Argo Rollouts

`apps/springboot/templates/rollout.yaml` define um `Rollout`
(`argoproj.io/v1alpha1`, Argo Rollouts) no lugar de um `Deployment` comum,
com `strategy.canary` apontando para `springboot-stable`/`springboot-canary`
(`service-stable.yaml`/`service-canary.yaml`). Os passos ficam em
`apps/springboot/values.yaml`:

```yaml
canary:
  steps:
    - setWeight: 50
    - pause: {}
    - setWeight: 100
```

50% de tráfego → **pausa indefinida** → 100%. O `pause` **não tem
`duration`** de propósito: o Argo Rollouts fica parado em 50% e **não
promove sozinho depois de X segundos** — é preciso aprovar manualmente
cada canário, dentro de cada shard (além da aprovação manual entre shards,
veja abaixo).

Os comandos pra acompanhar e promover um rollout (`kubectl argo rollouts
get`/`promote`) estão no passo a passo com o que esperar em cada um —
`TESTE-END-TO-END.md`, seções 7 e 11.

`spec.revisionHistoryLimit: 5` limita o histórico a só os 5 `ReplicaSet`
mais recentes por shard (o padrão do Argo Rollouts, se omitido, é 10) —
evita acumular `ReplicaSet`s órfãos de deploys/rollbacks antigos no
namespace.

### Entre shards: um único ApplicationSet do ArgoCD + aprovação manual

`terraform/platform/argocd-applicationset.tf` define **um único**
`ApplicationSet` (`springboot-shards`), que gera as duas `Application`
(`springboot-shard-1`/`springboot-shard-2`) apontando para o mesmo chart
(`apps/springboot`, `var.argocd_apps_path`), sobrescrevendo `shard`/
`namespace` via `spec.source.helm.parameters` a partir do parâmetro
`{{ .shard }}` de cada generator (`goTemplate: true`):

- **`spec.generators`** tem **dois** generators `list`, cada um com **1**
  elemento (`shard: shard-1` / `shard: shard-2`) — não um único generator
  com uma lista de 2 elementos, pelo motivo abaixo.
- O generator da shard-1 tem seu **próprio** `template` (aninhado dentro do
  `list:`) — uma cópia **completa e autossuficiente** do template
  (`metadata`, `project`, `source`, `destination`, `syncPolicy`), igual ao
  template top-level só que com `syncPolicy.automated` a mais — sincroniza
  sozinha assim que o chart mudar no Git.
- O generator da shard-2 **não** tem `template` nenhum — herda o template
  top-level inteiro, cujo `syncPolicy` só tem `syncOptions` (sem
  `automated`). Fica `OutOfSync` até alguém aprovar manualmente.

Por que dois generators de 1 elemento em vez de um generator com uma lista
de 2 elementos: o override de `template` no ArgoCD é aplicado por
**generator**, não por elemento dentro da lista de um mesmo generator — um
único generator `list` com os dois shards aplicaria o mesmo `template` (ou
a mesma ausência dele) aos dois, sem jeito de variar o `syncPolicy` por
elemento. Com dois generators (documentado oficialmente: [Template →
generator
templates](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Template/#generator-templates)),
cada um pode ter seu próprio override — ainda um único recurso
`ApplicationSet`, só que com `spec.generators` de 2 itens em vez de
`spec.generators[0].list.elements` de 2 itens.

Por que o `template` da shard-1 restata **tudo** (`metadata`/`project`/
`source`/`destination`), não só o `syncPolicy` que difere: na prática, o
CRD `ApplicationSet` valida o `template` de um generator contra o schema
**inteiro** de `ApplicationSetTemplate` assim que ele existe — ou seja,
`metadata`/`spec.project`/`spec.destination` viram campo obrigatório
("Required value") nesse ponto, mesmo que o controller depois faça merge
com o `spec.template` de baixo em tempo de reconciliação. Só sobrescrever
`spec.syncPolicy` (deixando o resto de fora) falha na admissão do
Kubernetes com `spec.generators[0].list.template.spec.destination:
Required value` (e o mesmo pra `project` e `metadata`) — foi exatamente o
erro visto ao aplicar essa versão pela primeira vez.

Fluxo típico de um deploy, em prosa (o passo a passo com todos os comandos
e o que esperar em cada etapa está em `TESTE-END-TO-END.md`, seções 5 a
11): uma mudança em `apps/` dispara o Argo Workflow (automático por
polling ou manual), que builda a imagem, dá push no ECR e atualiza
`apps/springboot/values.yaml` com commit/push automático → a
`springboot-shard-1` sincroniza sozinha e o canário da shard 1 pausa em
50% → promoção manual leva a shard 1 a 100% → só então a promoção da
shard-2 fica disponível para aprovação manual (`argocd app sync
springboot-shard-2`) → a `springboot-shard-2` sincroniza e o canário da
shard 2 (independente do da shard 1) também pausa em 50% até uma nova
promoção manual.

Se quiser progressão automática por etapas com pausas cronometradas em vez
de aprovação manual — nem dentro do canário (`pause: { duration: ... }` em
vez de `pause: {}`), nem entre shards (o ArgoCD tem um recurso nativo do
ApplicationSet pra isso, **Progressive Syncs**, `strategy.type:
RollingSync`) — nenhum dos dois é usado aqui de propósito, porque o
requisito pede explicitamente aprovação manual em ambos os níveis.

**Sobre a `Application` da shard-2 já aparecer `OutOfSync` com o commit
novo antes da shard-1 terminar:** isso é esperado e não é um deploy. As
duas `Application` (`springboot-shard-1`/`springboot-shard-2`) apontam
para o **mesmo** `targetRevision: HEAD` do mesmo repositório — então assim
que o Argo Workflow dá `git push` (mesmo com o canário da shard-1 ainda no
meio do caminho), o ArgoCD atualiza o diff/target da shard-2 pro commit
novo e ela vira `OutOfSync`. Isso é só comparação (o repo-server buscando o
Git e comparando com o cluster) — sem `syncPolicy.automated` nesse
generator, **nada é aplicado**: os pods da shard-2 continuam rodando a
versão anterior até alguém rodar `argocd app sync springboot-shard-2` de
verdade.

Dito isso, a ordem "shard-2 só depois que a shard-1 terminar" **não é
tecnicamente travada** hoje — nada no ApplicationSet impede alguém de
rodar esse `sync` da shard-2 enquanto a shard-1 ainda está no meio do
canário; é responsabilidade de quem opera confirmar que a shard-1 chegou a
100%/`Healthy` (`kubectl argo rollouts status springboot -n shard-1` ou
`argocd app get springboot-shard-1`) antes de aprovar a shard-2. Foi uma
escolha deliberada não adicionar uma trava automática aqui (ex.: um script
que bloqueia o `sync` da shard-2 checando o status da shard-1, ou uma ref
Git separada por shard promovida por uma etapa nova do Workflow) — para o
escopo deste desafio, manter os dois níveis como aprovação manual
(documentada e operada por humano) já atende ao requisito de aprovação
manual entre shards.

## CI: Argo Workflows (build + push automático no ECR + atualização do Git)

Sempre que algo muda em `apps/`, um **Argo Workflow** builda a imagem Java,
dá push no ECR e atualiza `apps/springboot/values.yaml` no Git — sem depender
de GitHub Actions nem de nenhum OIDC/secret configurado no lado do GitHub:
tudo roda **dentro do cluster**.

### Disparo automático (padrão): CronWorkflow com polling

`terraform/platform/argoworkflows-poller.tf` define um `CronWorkflow`
(`git-poll-trigger`, namespace `argo-workflows`) que roda a **cada 2
minutos** e:

1. faz `git ls-remote` no branch configurado (repositório público, sem
   credencial) e compara o commit SHA atual com o último já processado
   (guardado num `ConfigMap` `git-poll-state`);
2. se mudou, grava o novo SHA no `ConfigMap` e cria um novo `Workflow` a
   partir do mesmo `WorkflowTemplate` `build-push-springboot` usado pelo
   disparo manual (abaixo) — reaproveitando os parâmetros default definidos
   nele.

Ou seja: depois de um `git push` em `apps/`, o build começa sozinho em até
2 minutos, sem precisar rodar `argo submit`.

**Por que polling em vez de um webhook do GitHub (Argo Events)?** Foi uma
escolha deliberada: um webhook dispara instantaneamente, mas exige instalar
mais componentes (Argo Events: `EventBus`/`EventSource`/`Sensor`) e expor
um endpoint HTTP nesse EventSource alcançável pelo GitHub pela internet. O
polling não precisa de nenhum endpoint novo — é sempre o cluster puxando
informação do GitHub (saída), nunca o GitHub entrando no cluster (entrada).
Troca-se instantaneidade por menos superfície de exposição; para uma Demo,
o atraso de até 2 minutos é irrelevante. (A UI do Argo Workflows, à parte
disso, **já está** exposta publicamente — veja "Expondo o Argo Workflows
via LoadBalancer" abaixo — mas isso é uma decisão independente do disparo
do CI em si.)

### Disparo manual (opcional, para não esperar o polling)

`terraform/platform/argoworkflows-template.tf` define o `WorkflowTemplate`
`build-push-springboot` (namespace `argo-workflows`) com os passos:

1. **`clone-repo`** — clona `var.github_repo_url` e captura o commit SHA
   curto como tag da imagem.
2. **`maven-build`** — `mvn clean package` dentro de `apps/`, gerando
   `apps/target/springboot-sharded-app-1.0.0.jar` (o `Dockerfile` só copia
   o jar já pronto, não builda a app — por isso o Maven roda antes do
   Kaniko).
3. **`kaniko-build-push`** — builda `apps/Dockerfile` com
   [Kaniko](https://github.com/GoogleContainerTools/kaniko) (sem
   Docker-in-Docker) e dá push no ECR com a tag do passo 1.
4. **`update-values`** — atualiza `image.repository`/`image.tag` em
   `apps/springboot/values.yaml` e dá `git commit`+`push` — é esse push que
   a `Application` `springboot-shard-1` (`syncPolicy.automated`) detecta e
   sincroniza, disparando o canário descrito acima.

Disparo manual: com o [Argo Workflows CLI](https://argo-workflows.readthedocs.io/en/latest/walk-through/argo-cli/)
(`argo submit --from workflowtemplate/build-push-springboot`) ou pela UI
(via NLB ou port-forward). Os comandos exatos e o que esperar de cada um
estão em `TESTE-END-TO-END.md`, seção 5.

### Autenticação no ECR (IRSA) e no Git

- **ECR:** `argoworkflows-irsa.tf` registra o OIDC issuer nativo do cluster
  EKS como um IAM OIDC Identity Provider e cria uma role IAM (permissões só
  de push no repositório ECR do projeto) confiada a uma ServiceAccount
  específica (`argo-workflow-ecr-push`, namespace `argo-workflows`) — é o
  padrão **IRSA**. O Kaniko detecta automaticamente que o destino é um
  registro ECR (pelo hostname `*.dkr.ecr.*.amazonaws.com`) e usa as
  credenciais temporárias injetadas pelo webhook nativo do EKS nessa
  ServiceAccount — não há nenhum `docker login`/`aws ecr get-login-password`
  explícito no pipeline.
- **Git (push):** um Kubernetes Secret (`git-push-credentials`, criado por
  `argoworkflows-irsa.tf` a partir de `var.github_username`/
  `var.github_token`) é montado só no último passo (`update-values`), usado
  para construir a URL autenticada do `git push`. Preencha essas duas
  variáveis via `terraform/platform/environment/dev/secrets.tfvars` (copie
  de `secrets.tfvars.example`, **nunca** versione o arquivo real — já está
  no `.gitignore`).

⚠️ O repositório ECR é criado com `image_tag_mutability = IMMUTABLE`
(`terraform/infra/ecr.tf`): como a tag usada é o commit SHA, rodar o
Workflow duas vezes para o **mesmo** commit falha no push (a tag já existe)
— isso é esperado, é uma proteção contra sobrescrever uma imagem já
publicada, não um bug. Um commit novo sempre gera uma tag nova.

## Variáveis por ambiente

As variáveis que costumam mudar entre ambientes não têm `default` em
`variables.tf` — vêm de um var-file por ambiente, um por camada (veja
"Camadas do Terraform" acima). Exemplo (`terraform/infra/environment/dev/terraform.tfvars`):

```hcl
env                         = "dev"
aws_region                  = "us-east-1"
cluster_name                = "eks-automode-dev"
kubernetes_version           = "1.35"
ecr_repository_name         = "eks-automode-app-dev"
shard_instance_types         = ["m5.large", "m5a.large"]
shard_max_nodes             = 3
cluster_log_retention_days  = 1
```

E `terraform/platform/environment/dev/terraform.tfvars`:

```hcl
env                  = "dev"
aws_region           = "us-east-1"
cluster_name         = "eks-automode-dev"
shard_instance_types = ["m5.large", "m5a.large"]  # precisa bater com o de infra
shard_max_nodes      = 3                          # precisa bater com o de infra
ecr_repository_name  = "eks-automode-app-dev"     # precisa bater com o de infra

argocd_url           = "https://localhost:8080" # veja Notas — hoje não é usada por nenhum resource
github_repo_url      = "https://github.com/<org>/<repo>.git"
argocd_project_name  = "eks-shards"
argocd_apps_path     = "apps/springboot"

node_role_name       = "eks-automode-dev-node-role"
```

Mais `terraform/platform/environment/dev/secrets.tfvars` (gitignorado,
copiado de `secrets.tfvars.example`), com `github_username`/`github_token`
— **obrigatório** desde que o Argo Workflow foi adicionado (sem default,
o `terraform apply` da camada `platform` falha sem ele):

```hcl
github_username = "seu-usuario-github"
github_token     = "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

Para um novo ambiente (ex.: `prod`), crie `environment/prod/terraform.tfvars`
(e `secrets.tfvars`) em cada camada, com os mesmos nomes de variável e
valores diferentes.

## Integração ArgoCD ↔ GitHub (Project e Secret)

- `argocd-project.tf` — `AppProject` (`var.argocd_project_name`, padrão
  `eks-shards`) restringindo `sourceRepos` ao repositório em
  `var.github_repo_url`.
- `argocd-github-secret.tf` — Secret `argocd-github-credentials` no
  namespace `argocd` com credenciais do repositório Git, usado pelo
  **ArgoCD** para clonar (diferente do `git-push-credentials` usado pelo
  **Argo Workflow**, veja "CI: Argo Workflows" acima — são dois secrets
  independentes, para dois consumidores diferentes). **Está inteiro
  comentado no código hoje** — ou seja, o ArgoCD hoje só consegue clonar
  `var.github_repo_url` se ele for **público**. Para repositório privado,
  descomente o resource (ele já pode reaproveitar `var.github_username`/
  `var.github_token`, que agora existem em `variables.tf` por causa do Argo
  Workflow).

⚠️ `var.github_repo_url` precisa apontar para **este** repositório (ou para
onde `apps/springboot` foi publicado) — é de lá que as duas Applications
geradas pelo ApplicationSet (veja acima) e o Argo Workflow buscam/atualizam
o chart.

Se um token vazar (por exemplo, colado em um chat ou commitado por engano),
revogue-o imediatamente em https://github.com/settings/tokens e gere um novo.

### Expondo o ArgoCD via LoadBalancer (NLB)

O `server.service` do ArgoCD está configurado em
`terraform/platform/environment/dev/argocd.yaml` como `type: LoadBalancer`, com:

```yaml
annotations:
  service.beta.kubernetes.io/aws-load-balancer-type: "external"
  service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
  service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
loadBalancerClass: "eks.amazonaws.com/nlb"
externalTrafficPolicy: Local
```

O **EKS Auto Mode provisiona o Network Load Balancer automaticamente** para
esse Service — não é preciso instalar o AWS Load Balancer Controller.
`aws-load-balancer-type: external` é o valor exigido pelo controller nativo
do Auto Mode (o antigo `nlb`, do cloud-provider in-tree, não funciona nele).

**Atenção:** o `scheme` está como `internet-facing` (NLB público). Se quiser
o NLB privado (recomendado para dev), troque para:

```yaml
service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
```

O provisionamento do NLB é **assíncrono** — nos primeiros minutos depois do
apply, o hostname pode ainda não existir. Os comandos pra pegar o
hostname/senha (incluindo o script `scripts/02-get-argocd-lb-address-and-password.sh`)
estão em `TESTE-END-TO-END.md`, apêndice "Acessar ArgoCD/Argo Workflows via NLB".

### Expondo o Argo Workflows via LoadBalancer (NLB)

Mesmo padrão do ArgoCD acima, configurado em
`terraform/platform/environment/dev/argo-workflows.yaml` (chart
`argo-workflows`, que usa chaves no nível raiz de `server:` em vez de
`server.service.*`):

```yaml
server:
  serviceType: LoadBalancer
  serviceAnnotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
  loadBalancerClass: "eks.amazonaws.com/nlb"
```

**Atenção — `scheme: internet-facing` (NLB público) é uma decisão explícita
do usuário**, e combinada com `--auth-mode=server` (UI/API sem exigir login
SSO, veja acima) significa que **qualquer pessoa com o hostname do NLB
consegue ver e submeter/abortar Workflows sem autenticação** — não é só
visualizar a UI, é controle real sobre o pipeline de CI (inclusive
disparar/abortar o `build-push-springboot`). Aceitável para uma Demo/teste
de curta duração; se precisar restringir de novo ao acesso interno da VPC,
troque para:

```yaml
service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
```

O hostname do NLB pode levar alguns minutos para ficar disponível
(provisionamento assíncrono, igual ao do ArgoCD). A UI do Argo Workflows
usa HTTPS com certificado autoassinado por padrão — o navegador vai avisar,
é esperado (aceite o risco/prossiga). O comando pra pegar o hostname está
em `TESTE-END-TO-END.md`, apêndice "Acessar ArgoCD/Argo Workflows via NLB".

### Expondo as apps das shards via LoadBalancer (NLB)

`apps/springboot/templates/service-stable.yaml` (o Service que aponta só
para os pods **estáveis**, promovidos pelo Argo Rollouts — não para a
`canary`) está como `type: LoadBalancer`, com o mesmo padrão de anotações
do ArgoCD/Argo Workflows acima:

```yaml
annotations:
  service.beta.kubernetes.io/aws-load-balancer-type: "external"
  service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
  service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
spec:
  type: LoadBalancer
  loadBalancerClass: eks.amazonaws.com/nlb
```

Esse chart (`apps/springboot`) é o **mesmo** aplicado nas duas shards pelo
ApplicationSet — só `shard`/`namespace` mudam via
`spec.source.helm.parameters` (veja "Entre shards" acima). Por isso essa
única mudança no chart já provisiona **dois** NLBs, um em cada namespace de
shard (`shard-1`/`shard-2`), sem precisar de nenhum recurso Terraform novo.

`service-canary.yaml` (os pods em canário, ainda não promovidos)
**continua só `ClusterIP`** de propósito — só a versão já promovida/estável
de cada shard fica exposta publicamente; a canary só é acessível via
`port-forward`, o que é aceitável já que ela existe por pouco tempo durante
um deploy.

**Atenção — custo e exposição:** isso soma mais dois NLBs `internet-facing`
aos já existentes (ArgoCD, Argo Workflows) — 4 NLBs no total no ambiente
`dev`. A aplicação de exemplo não tem autenticação, então qualquer pessoa
com o hostname consegue acessar os endpoints dela; aceitável para uma
Demo. Os comandos para pegar o hostname de cada shard e testar a resposta
da aplicação estão em `TESTE-END-TO-END.md`.

### Sobre "Argo CD URL: https://null"

`var.argocd_url` está declarada em `terraform/platform/variables.tf` mas
não é consumida por nenhum resource hoje. Se quiser fixar a URL exibida
pelo ArgoCD, defina `configs.cm.url` diretamente em
`terraform/platform/environment/dev/argocd.yaml`:

```yaml
configs:
  cm:
    url: "https://<hostname-do-nlb-ou-seu-dominio>"
```

## Como iniciar (rodar a app localmente, sem o cluster)

Útil para desenvolver/testar a app antes de subir infra: `cd apps && mvn
spring-boot:run` sobe a aplicação Spring Boot local, sem depender de
nenhuma parte da infra AWS/Kubernetes. `APP_VERSION`/`APP_SHARD` (env vars,
ver `Dockerfile`/`rollout.yaml`) alimentam `app.version`/`app.shard`
(`application.properties`) — em produção cada shard reporta o próprio nome
em `/`; localmente, sem essas env vars, `shard` aparece como `"unknown"`.
Os comandos completos (incluindo os `curl` de verificação) estão em
`TESTE-END-TO-END.md`, apêndice "Testar a app localmente, sem o cluster".

## Como provisionar

Ordem sempre **infra primeiro, platform depois** — o passo a passo
completo com todos os comandos, o que esperar em cada etapa e como
resolver os problemas mais comuns está em `TESTE-END-TO-END.md`. Resumo:

```bash
# Etapa 1 — infraestrutura AWS (VPC, IAM, cluster EKS, ECR)
cd terraform/infra
terraform init
terraform apply -var-file=environment/dev/terraform.tfvars

# Etapa 2 — NodePools, NodeClasses, ArgoCD, Argo Rollouts, Argo Workflows, Project e ApplicationSet
cd ../platform
cp environment/dev/secrets.tfvars.example environment/dev/secrets.tfvars
# edite environment/dev/secrets.tfvars com seu github_username/github_token
terraform init
terraform apply \
  -var-file=environment/dev/terraform.tfvars \
  -var-file=environment/dev/secrets.tfvars
```

`secrets.tfvars` (`github_username`/`github_token`) é **obrigatório** desde
que o Argo Workflow foi adicionado — sem ele, o `apply` da camada `platform`
para num prompt interativo pedindo essas variáveis. Se você também reativou
`argocd-github-secret.tf` (repositório privado para o ArgoCD), o mesmo
arquivo já cobre isso, já que reaproveita as mesmas variáveis.

Isso cria a VPC, o cluster EKS com Auto Mode, os dois NodePools shard
(isolados por taint), o repositório ECR e instala o ArgoCD + Argo Rollouts +
Argo Workflows nos namespaces `argocd`, `argo-rollouts` e `argo-workflows`
— além do `AppProject`, das duas `Application` (`springboot-shard-1`/
`springboot-shard-2`), do `WorkflowTemplate` `build-push-springboot` e do
`CronWorkflow` `git-poll-trigger`.

## Build e push manual da imagem (alternativa ao Argo Workflow)

`scripts/build-push.sh`/`build-push.ps1` fazem o build Maven e o
build+push da imagem Docker direto no ECR, sem passar pelo Argo Workflow —
útil pra testar uma mudança rapidamente sem esperar os 4 passos do
pipeline completo. Diferença importante: os scripts **não** atualizam
`apps/springboot/values.yaml` nem dão commit/push (o Argo Workflow faz
isso automaticamente no passo `update-values`) — depois de usar os
scripts, esse passo fica por sua conta. Os comandos de uso estão em
`TESTE-END-TO-END.md`, apêndice "Build e push manual da imagem".

## Logs do control plane

Os 5 tipos de log do control plane estão habilitados (`api`, `audit`,
`authenticator`, `controllerManager`, `scheduler`), enviados para o log group
`/aws/eks/<cluster_name>/cluster` no CloudWatch, com retenção configurável em
`var.cluster_log_retention_days` (no `terraform.tfvars` de dev atual: **1
dia** — ajuste para produção). Isso cobre apenas os logs do **control
plane**. Logs de aplicação (stdout dos pods) não passam por aqui — no EKS
Auto Mode, use algo como o CloudWatch Observability add-on ou um DaemonSet
de coleta (Fluent Bit) para isso. O comando pra visualizar os logs está em
`TESTE-END-TO-END.md`, apêndice "Ver logs do control plane".

## Como destruir o ambiente

Ordem inversa da criação — **platform primeiro, depois infra** (o cluster
precisa continuar de pé para o Terraform conseguir remover graciosamente os
recursos Kubernetes/Helm da camada platform):

```bash
cd terraform/platform
terraform destroy \
  -var-file=environment/dev/terraform.tfvars \
  -var-file=environment/dev/secrets.tfvars

cd ../infra
terraform destroy -var-file=environment/dev/terraform.tfvars
```

Se `platform` já tiver sido destruído manualmente/parcialmente (ex.: o
cluster foi apagado primeiro por engano), `terraform destroy` da camada
`platform` pode travar tentando falar com um cluster que não existe mais —
nesse caso, `terraform state rm` os resources problemáticos antes de tentar
de novo, ou destrua com `-target` resource a resource.

## Notas / problemas conhecidos

- **`argocd-github-secret.tf` desabilitado:** hoje o ArgoCD só autentica em
  repositórios GitHub públicos (veja acima) — não afeta o Argo Workflow, que
  usa seu próprio Secret (`git-push-credentials`).
- **`var.argocd_url` não é usada** por nenhum resource — corrija a URL do
  ArgoCD via `configs.cm.url` em `argocd.yaml` (veja acima).
- **`var.ecr_repository_url`, `var.git_revision`, `var.shard_instance_types`
  e `var.shard_max_nodes` em `terraform/infra/variables.tf`** ficaram sem
  nenhum consumidor dentro de `infra` depois da divisão em duas camadas
  (o que os usava — NodePools — está todo em `platform` agora). Continuam
  declaradas para não quebrar o `terraform.tfvars` existente; seguro
  remover se quiser limpar.
- **Storage do workspace do Argo Workflow:** o `WorkflowTemplate` usa um
  `volumeClaimTemplates` (PVC dinâmico via EBS) para compartilhar o clone do
  repo/build entre os passos `clone-repo` → `maven-build` →
  `kaniko-build-push` → `update-values`, já que cada passo do Argo Workflows
  roda num Pod separado (um `emptyDir` não sobreviveria entre eles). A
  StorageClass usada (`auto-ebs-sc`, `storageclass.tf`) **precisa** ser
  criada manualmente — ao contrário do que o nome "block storage
  capability" sugere, o EKS Auto Mode **não** cria nenhuma StorageClass
  sozinho, e usa um provisioner próprio (`ebs.csi.eks.amazonaws.com`, com
  "eks" no meio) diferente do driver EBS CSI clássico
  (`ebs.csi.aws.com`, que não roda no Auto Mode). Se você usar a
  StorageClass `gp2` que já vem em qualquer cluster EKS (CSI migration do
  provisioner legado `kubernetes.io/aws-ebs` para `ebs.csi.aws.com`), o PVC
  fica preso pra sempre em `Pending` — sintoma: evento `ExternalProvisioning
  ... Waiting for a volume to be created by the external provisioner
  'ebs.csi.aws.com'` seguido de `context deadline exceeded` no bind.
- Para produção, considere múltiplos NAT Gateways (`single_nat_gateway = false`
  em `vpc.tf`), backend remoto (S3 + DynamoDB) para o state — **de cada
  camada**, já que agora são dois states independentes —, exposição do
  ArgoCD/Argo Workflows via Ingress/ALB com TLS e HA (`redis-ha.enabled = true`,
  mais réplicas no `argocd.yaml`), e trocar o disparo automático por
  polling (`argoworkflows-poller.tf`) por Argo Events + webhook do GitHub
  se precisar de disparo instantâneo em vez de até 2 min de atraso (veja
  "Decisões de arquitetura" acima).
- Instâncias Spot podem ser interrompidas pela AWS a qualquer momento — não
  use os shards para workloads stateful sem tolerância a disrupção.
