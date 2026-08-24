# Deploy Gradual em EKS com Arquitetura em Shards

Cluster EKS com **EKS Auto Mode**, dois NodePools que funcionam como
**shards fisicamente isolados** (Spot, Bottlerocket, taint dedicado, máximo
aproximado de 3 EC2 cada), um repositório ECR, o **ArgoCD**, o **Argo
Rollouts** e o **Argo Workflows** instalados via Helm, e uma aplicação
Java/Spring Boot de exemplo cujo deploy é gradual em dois níveis:

- **Dentro de cada shard**: canário controlado pelo **Argo Rollouts**
  (`Rollout` em vez de `Deployment`, com passos de peso/pausa).
- **Entre as shards**: promovido por duas `Application` do ArgoCD geradas
  por **ApplicationSet**, que só sincroniza a segunda shard depois de uma
  **aprovação manual**.

O disparo de tudo começa com uma mudança em `apps/`: um **Argo Workflow**
(disparado manualmente, veja "CI: Argo Workflows" abaixo) builda a imagem,
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
| ApplicationSet do ArgoCD controla o deploy entre shards | `terraform/platform/argocd-applicationset.tf` (uma `Application` por shard) |
| Toda a infra criada pelo candidato (EKS, EC2, app Java) | `terraform/infra` + `terraform/platform` + `apps/` |
| IaC | Terraform (`terraform/infra`, `terraform/platform`) |
| Uma região/uma conta AWS | `var.aws_region` único, sem multi-account/multi-region |
| Helm para empacotamento | `apps/springboot` (chart da app) + ArgoCD/Argo Rollouts/Argo Workflows instalados via `helm_release` |
| README com visão geral, como iniciar, provisionar e destruir | este arquivo |

## Pré-requisitos

- Terraform >= 1.4.4
- AWS CLI configurado com credenciais válidas
- Helm >= 3.8 (usado internamente pelo provider `helm`)
- Permissões IAM para criar VPC, EKS, IAM Roles (incluindo um IAM OIDC
  Identity Provider para o cluster), ECR
- `kubectl` + [plugin do Argo Rollouts](https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation) (`kubectl argo rollouts`), útil para acompanhar o canário
- [ArgoCD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) (`argocd`), útil para dar a aprovação manual entre shards
- [Argo Workflows CLI](https://argo-workflows.readthedocs.io/en/latest/walk-through/argo-cli/) (`argo`), usado para disparar manualmente o build+push da imagem (veja "CI: Argo Workflows" abaixo)
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
- `argocd-applicationset.tf` — duas `Application` (uma por shard), aprovação manual a partir da 2ª
- `argorollouts.tf` — instalação do Argo Rollouts via Helm (namespace `argo-rollouts`)
- `argoworkflows.tf` — instalação do Argo Workflows via Helm (namespace `argo-workflows`)
- `argoworkflows-irsa.tf` — IAM OIDC Identity Provider do cluster + role/policy IRSA (push no ECR) + ServiceAccount + Secret de credenciais Git
- `argoworkflows-template.tf` — `WorkflowTemplate` com os passos de build+push+atualização do Git
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

Acompanhar um rollout em andamento:

```bash
kubectl argo rollouts get rollout springboot -n shard-1 --watch
```

Enquanto ele estiver pausado em 50% (`Status: Paused`), promova manualmente
para 100%:

```bash
kubectl argo rollouts promote springboot -n shard-1
# ou, pra pular direto pra 100% sem passar pelos steps seguintes:
kubectl argo rollouts promote springboot -n shard-1 --full
```

(troque `shard-1` por `shard-2` quando for promover o canário da shard 2.)

### Entre shards: duas Applications do ArgoCD + aprovação manual

`terraform/platform/argocd-applicationset.tf` define **duas** `Application`
do ArgoCD (`springboot-shard-1`/`springboot-shard-2`), ambas apontando para
o mesmo chart (`apps/springboot`, `var.argocd_apps_path`), sobrescrevendo só
`shard`/`namespace` via `spec.source.helm.parameters`:

- **`springboot-shard-1`** tem `syncPolicy.automated` — sincroniza sozinha
  assim que o chart mudar no Git (ex.: o Argo Workflow atualizando
  `image.tag`/`image.repository` em `values.yaml`), disparando o canário do
  Argo Rollouts na shard 1.
- **`springboot-shard-2`** **não** tem `syncPolicy.automated` — fica
  `OutOfSync` até alguém aprovar manualmente.

São dois `kubectl_manifest` fixos (não um único `ApplicationSet` com um
generator de lista com 2 itens) porque o `syncPolicy.automated` da shard-1
precisa existir e o da shard-2 precisa estar **totalmente ausente** — e o
`goTemplate` do ArgoCD só substitui valores escalares dentro de uma
estrutura YAML já válida, não consegue incluir/omitir uma chave YAML
inteira condicionalmente (um `{{- if }}` no lugar de uma chave gera YAML
inválido antes mesmo do Kubernetes processar o manifest). Duas Applications
estáticas, cada uma com o `syncPolicy` certo hardcoded, evitam esse
problema por completo.

Fluxo típico de um deploy:

1. Altere algo em `apps/` (código Java, `Dockerfile`, chart) e dê commit/push.
2. Dispare o Argo Workflow manualmente (veja "CI: Argo Workflows" abaixo) —
   ele builda a imagem, dá push no ECR com uma tag nova (o commit SHA
   curto) e atualiza `apps/springboot/values.yaml` com commit/push
   automático.
3. `springboot-shard-1` sincroniza sozinha → o `Rollout` da shard 1 começa o
   canário e **pausa em 50%** (`Status: Paused`).
4. Acompanhe: `kubectl argo rollouts get rollout springboot -n shard-1 --watch`.
5. Satisfeito com os 50% na shard 1, **promova manualmente** para 100%:

   ```bash
   kubectl argo rollouts promote springboot -n shard-1
   ```

6. Satisfeito com a shard 1 em 100%, **aprove manualmente** a promoção para a shard 2:

   ```bash
   argocd app sync springboot-shard-2
   # ou, via kubectl apontando pro cluster diretamente, sem precisar da UI do ArgoCD:
   kubectl patch application springboot-shard-2 -n argocd --type merge \
     -p '{"operation":{"sync":{"revision":"HEAD"}}}'
   ```

   (o primeiro comando é o caminho recomendado; o `kubectl patch` é um
   fallback se você não tiver o ArgoCD CLI configurado.)
7. `springboot-shard-2` sincroniza → o `Rollout` da shard 2 começa o
   **seu próprio** canário, independente do da shard 1, e também **pausa em
   50%** até você rodar `kubectl argo rollouts promote springboot -n shard-2`.

Se quiser progressão automática por etapas com pausas cronometradas em vez
de aprovação manual — nem dentro do canário (`pause: { duration: ... }` em
vez de `pause: {}`), nem entre shards (o ArgoCD tem um recurso nativo do
ApplicationSet pra isso, **Progressive Syncs**, `strategy.type:
RollingSync`) — nenhum dos dois é usado aqui de propósito, porque o
requisito pede explicitamente aprovação manual em ambos os níveis.

## CI: Argo Workflows (build + push automático no ECR + atualização do Git)

Sempre que algo muda em `apps/`, um **Argo Workflow** builda a imagem Java,
dá push no ECR e atualiza `apps/springboot/values.yaml` no Git — sem depender
de GitHub Actions nem de nenhum OIDC/secret configurado no lado do GitHub:
tudo roda **dentro do cluster**, disparado **manualmente** (não há Argo
Events/webhook nenhum "escutando" o repositório — mais simples para uma
Demo).

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

Disparar manualmente com o [Argo Workflows CLI](https://argo-workflows.readthedocs.io/en/latest/walk-through/argo-cli/):

```bash
argo submit --from workflowtemplate/build-push-springboot -n argo-workflows --watch
```

Ou pela UI do Argo Workflows — exposta via NLB (veja "Expondo o Argo
Workflows via LoadBalancer" abaixo) ou, sem esperar o hostname do NLB, via
port-forward:

```bash
kubectl port-forward svc/argo-workflows-server -n argo-workflows 2746:2746
# abra https://localhost:2746 e dispare o WorkflowTemplate build-push-springboot
```

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
apply, o hostname pode ainda não existir:

```bash
kubectl get svc -n argocd argocd-argocd-server
```

Ou use `scripts/02-get-argocd-lb-address-and-password.sh` (imprime a senha
inicial do admin e a URL — assume um binário `jq` no PATH chamado
`jq-windows-amd64.exe`, ajuste se necessário).

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
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
  loadBalancerClass: "eks.amazonaws.com/nlb"
```

Diferente do ArgoCD (`internet-facing` por padrão hoje), aqui o `scheme`
já vem como `internal` — a UI do Argo Workflows dá visibilidade sobre o
pipeline de build e credenciais de Git/ECR indiretamente, então o padrão é
só acessível de dentro da VPC (bastion/VPN). Troque para `internet-facing`
se precisar expor publicamente.

```bash
kubectl get svc -n argo-workflows argo-workflows-server
```

O hostname do NLB pode levar alguns minutos para ficar disponível
(provisionamento assíncrono, igual ao do ArgoCD). A UI do Argo Workflows
usa HTTPS com certificado autoassinado por padrão — o navegador vai avisar,
é esperado (aceite o risco/prossiga).

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

Útil para desenvolver/testar a app antes de subir infra:

```bash
cd apps
mvn spring-boot:run
# ou: mvn clean package -DskipTests && java -jar target/springboot-sharded-app-1.0.0.jar
```

```bash
curl http://localhost:8080/
# {"application":"springboot-sharded-app","version":"1.0.0","shard":"unknown"}
curl http://localhost:8080/health
curl http://localhost:8080/actuator/health/readiness
```

`APP_VERSION`/`APP_SHARD` (env vars, ver `Dockerfile`/`rollout.yaml`)
alimentam `app.version`/`app.shard` (`application.properties`) — em
produção cada shard reporta o próprio nome em `/`.

## Como provisionar

Ordem sempre **infra primeiro, platform depois**:

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
`springboot-shard-2`) e do `WorkflowTemplate` `build-push-springboot`.

Configurar o kubectl:

```bash
aws eks update-kubeconfig --region us-east-1 --name eks-automode-dev
```

Publicar a primeira imagem e disparar o primeiro deploy (veja "CI: Argo
Workflows" acima):

```bash
argo submit --from workflowtemplate/build-push-springboot -n argo-workflows --watch
```

Verificar os NodePools, NodeClasses e as Applications geradas:

```bash
kubectl get nodepools
kubectl get nodeclasses
kubectl get applications -n argocd
```

Acessar o ArgoCD via NLB (se o hostname já estiver disponível — veja
"Expondo o ArgoCD via LoadBalancer" acima) ou via port-forward:

```bash
kubectl port-forward svc/argocd-argocd-server -n argocd 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

Login: `admin` / senha acima, em https://localhost:8080

## Build e push manual da imagem (alternativa ao Argo Workflow)

Útil para testar rapidamente sem passar pelo pipeline completo:

```bash
# Linux/macOS
./scripts/build-push.sh 1.0.0

# Windows
./scripts/build-push.ps1 -Tag 1.0.0
```

Sobrescreva `ECR_REPOSITORY`/`AWS_REGION` (bash) ou `-Repository`/`-Region`
(PowerShell) se o seu ambiente usar outro nome/região — o `terraform.tfvars`
de dev usa `eks-automode-app-dev`, por exemplo.

⚠️ O repositório ECR é criado com `image_tag_mutability = IMMUTABLE`
(`terraform/infra/ecr.tf`) — cada push precisa de uma tag **nova** (ex.:
`1.0.1`, `1.0.2`...); tentar sobrescrever uma tag já publicada falha. Depois
do push, atualize `image.tag`/`image.repository` em
`apps/springboot/values.yaml` manualmente e dê commit/push para disparar o
deploy gradual descrito acima (o Argo Workflow faz esses dois últimos
passos automaticamente).

## Logs do control plane

Os 5 tipos de log do control plane estão habilitados (`api`, `audit`,
`authenticator`, `controllerManager`, `scheduler`), enviados para o log group
`/aws/eks/<cluster_name>/cluster` no CloudWatch, com retenção configurável em
`var.cluster_log_retention_days` (no `terraform.tfvars` de dev atual: **1
dia** — ajuste para produção).

```bash
aws logs tail /aws/eks/eks-automode-dev/cluster --follow
```

Isso cobre apenas os logs do **control plane**. Logs de aplicação (stdout dos
pods) não passam por aqui — no EKS Auto Mode, use algo como o CloudWatch
Observability add-on ou um DaemonSet de coleta (Fluent Bit) para isso.

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
  mais réplicas no `argocd.yaml`), e um gatilho automático (Argo Events +
  webhook do GitHub, por exemplo) em vez do disparo manual do Argo Workflow.
- Instâncias Spot podem ser interrompidas pela AWS a qualquer momento — não
  use os shards para workloads stateful sem tolerância a disrupção.
