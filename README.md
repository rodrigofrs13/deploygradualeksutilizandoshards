# Deploy gradual em EKS com arquitetura em shards

Este projeto nasceu de um desafio técnico: montar, do zero, um cluster Kubernetes na AWS onde uma aplicação Java fosse implantada de forma
**gradual e controlada**, em duas frentes ao mesmo tempo — dentro de cada "fatia" (shard) do cluster, e entre as fatias. Neste artigo eu conto como
cheguei na arquitetura final, as decisões que tomei no meio do caminho (e por que descartei as alternativas), e os perrengues reais que apareceram
quando fui rodar tudo de verdade em uma conta AWS.

Se você só quer subir o ambiente, pule direto para "Como rodar". Se quer entender o raciocínio por trás de cada peça, seguiu o texto na ordem — é
assim que eu fui construindo.

Lembrando que esse é um ambiente de teste. NÃO RODAR EM PRODUÇÃO.

## O desafio

Criar um cluster EKS com pelo menos dois NodePools isolados fisicamente entre si ("shards"), uma aplicação Java/Spring Boot buildada e
publicada num repositório ECR próprio, e um deploy gradual em dois níveis — um Canary Deploy dentro de cada shard e uma promoção controlada (com aprovação
manual) de uma shard pra outra, orquestrada por um `ApplicationSet` do ArgoCD. Tudo em IaaS e com Helm Chart.

Existe também um desafio extra: Automatizar a promoção entre shards usando um alarme do CloudWatch como critério de decisão em vez de uma aprovação. Até o monento estou em testes desse desafio.

## A arquitetura que montei

Decidi usar **EKS Auto Mode** em vez de gerenciar node groups/Karpenter na
mão — a AWS cuida do provisionamento de nodes (via Karpenter por baixo,
mas com uma API própria de `NodeClass`/`NodePool`), da AMI (sempre
Bottlerocket) e até do Load Balancer Controller nativo. Isso tirou um bocado
de peça móvel do projeto, mas trouxe algumas particularidades que só descobri
na prática (conto no meio do texto).

Em cima disso, a pilha ficou:

- **Dois NodePools** (`shard-1`/`shard-2`), cada um com seu próprio taint —
  isolamento físico de verdade, não só um `nodeSelector`.
- **ECR** para a imagem da aplicação.
- **ArgoCD** cuidando do GitOps: um `ApplicationSet` único gerando as duas
  `Application` (uma por shard).
- **Argo Rollouts** fazendo o Canary Deploy *dentro* de cada shard.
- **Argo Workflows** rodando o pipeline de build+push+atualização — decidi
  não usar GitHub Actions, pra manter tudo rodando dentro do próprio
  cluster, sem precisar configurar OIDC ou secrets do lado do GitHub.

O código Terraform ficou dividido em **duas camadas com states
independentes**: `terraform/infra` (VPC, IAM, o cluster EKS em si, ECR — só
usa o provider `aws`) e `terraform/platform` (tudo que roda *dentro* do
cluster: NodeClasses, NodePools, ArgoCD, Rollouts, Workflows — usa `aws`,
`kubernetes`, `helm`, `kubectl` e `tls`). Separei assim porque misturar os
dois num state só faz qualquer erro de sintaxe num manifest Kubernetes
arriscar o cluster inteiro num único `terraform apply`; com states
separados, aplico a infra base, confirmo que o cluster subiu, e só depois
aplico a camada de plataforma — sempre nessa ordem, sem `-target`.

## Isolando as shards de verdade

Cada shard é um par `NodeClass`+`NodePool` (`terraform/platform/nodeclasses.tf`,
`nodepools.tf`). O ponto que me interessava resolver direito era: um
`nodeSelector` sozinho garante que o pod da aplicação *vá* pro node certo,
mas não impede que **outros** pods (sem esse seletor) também caiam ali —
não é isolamento, é só direcionamento. Resolvi isso com um **taint**
(`shard=shard-1:NoSchedule` / `shard=shard-2:NoSchedule`): só pods com a
`toleration` correspondente conseguem ser agendados nesses nodes. O
`Rollout` da aplicação já declara essa toleration.

Uma limitação que só descobri ao tentar implementar "no máximo 3 EC2 por
shard": o Karpenter (base do Auto Mode) **não tem** um campo nativo de
contagem máxima de instâncias — os limites de um `NodePool` são sempre por
soma de recursos (`limits.cpu`/`limits.memory`). Contornei isso calculando
o limite de CPU/memória com base no **maior** tipo de instância aceito,
multiplicado pelo teto desejado (`locals.tf`) — assim, mesmo que o
Karpenter só consiga capacidade do tipo maior do conjunto, o teto nunca é
ultrapassado. Funciona, mas é uma aproximação, não uma trava exata por
contagem.

## O deploy gradual em dois níveis

### Dentro da shard: Canary Deploy com Argo Rollouts

Troquei o `Deployment` padrão por um `Rollout` (CRD do Argo Rollouts), com
os passos do Canary Deploy definidos em `apps/springboot/values.yaml`:

```yaml
canary:
  steps:
    - setWeight: 50
    - pause: {}
    - setWeight: 100
```

O detalhe importante aqui é o `pause: {}` **sem** `duration`. Pensei
inicialmente em pausas cronometradas (promove sozinho depois de X
segundos), mas o requisito era aprovação manual — então o rollout fica
parado em 50% indefinidamente até alguém rodar `kubectl argo rollouts
promote springboot -n shard-1` (ou o plugin equivalente).

### Entre shards: um único ApplicationSet, aprovação manual

Esse foi o ponto onde apanhei mais. O requisito pedia **um** `ApplicationSet`
controlando o deploy nas duas shards — não dois recursos separados. Minha
primeira tentativa foi um único generator `list` com os dois shards como
elementos. Não funciona: o override de `template` no ArgoCD é aplicado por
**generator**, não por elemento dentro da lista — então dava pra variar
tudo entre as shards, menos o `syncPolicy` (que era exatamente o que eu
precisava diferenciar, pra shard-1 sincronizar sozinha e shard-2 esperar
aprovação).

A solução foi usar **dois generators `list`** dentro do mesmo
`ApplicationSet` (um por shard, cada um com um único elemento) — aí sim
cada generator pode ter seu próprio `template` override. O generator da
shard-1 tem um `template` com `syncPolicy.automated`; o da shard-2 não tem
`template` nenhum, herdando o `syncPolicy` do template top-level (sem
`automated`) — fica `OutOfSync` até um `argocd app sync
springboot-shard-2` manual.

Achei que bastaria sobrescrever só o `syncPolicy` no generator da shard-1,
mas a validação do CRD `ApplicationSet` exige o schema **inteiro** do
template assim que qualquer campo dele existe — `metadata`/`project`/
`destination` viram "Required value" nesse ponto, mesmo que o controller
faça merge depois. Precisei copiar o template inteiro, não só o campo que
mudava. Foi o tipo de erro que só aparece rodando `terraform apply` de
verdade (`spec.generators[0].list.template.spec.destination: Required
value`), não em nenhuma validação estática.

Um efeito colateral curioso que vale registrar: como as duas `Application`
apontam pro **mesmo** `targetRevision: HEAD` do mesmo repositório, assim
que o pipeline dá `git push`, a `Application` da shard-2 já aparece
`OutOfSync` — mesmo com o Canary Deploy da shard-1 ainda no meio do caminho. Isso
é só comparação (o `repo-server` do ArgoCD vendo que o Git mudou), não um
deploy: sem `syncPolicy.automated` nesse generator, nada é de fato aplicado
até alguém confirmar.

## Automatizando o build com Argo Workflows

Toda vez que algo muda em `apps/`, quero que a imagem seja buildada, publicada
no ECR e o `values.yaml` atualizado — sem eu precisar rodar nada manualmente
a maior parte do tempo. Decidi fazer isso com um `WorkflowTemplate` do Argo
Workflows em vez de GitHub Actions: assim tudo roda **dentro do cluster**,
sem precisar configurar OIDC nem secrets do lado do GitHub.

O pipeline (`terraform/platform/argoworkflows-template.tf`) faz, em
sequência: clona o repositório e captura o SHA do commit como tag da
imagem → `mvn clean package` → build da imagem com **Kaniko** (sem
Docker-in-Docker — importante, porque não tem daemon Docker disponível
dentro dos pods do cluster) → push no ECR → atualiza
`apps/springboot/values.yaml` com a nova tag e dá `git commit`+`push`. É
esse push que a `Application` da shard-1 (que tem `syncPolicy.automated`)
detecta e sincroniza sozinha, disparando o Canary Deploy.

Pra autenticar no ECR sem guardar nenhuma credencial estática no cluster,
usei **IRSA** (IAM Roles for Service Accounts): registrei o OIDC issuer
nativo do próprio cluster EKS como um IAM OIDC Identity Provider, e criei
uma role IAM com permissão só de push no repositório específico, confiada
apenas à ServiceAccount usada pelo Workflow (restrita pelo `sub` do token —
não é "qualquer pod do cluster consegue"). O Kaniko detecta sozinho que o
destino é ECR e usa as credenciais temporárias que o webhook do EKS injeta
automaticamente — nenhum `docker login` explícito em lugar nenhum.

### Disparo automático: preferi polling a webhook

Pra não depender de rodar `argo submit` manualmente toda vez, criei um
`CronWorkflow` que faz polling no Git periodicamente (`git ls-remote`),
compara com o último SHA processado, e dispara um novo build só se algo
realmente mudou. Cheguei a considerar Argo Events (webhook do GitHub) —
seria instantâneo — mas decidi por polling: não expõe nenhum endpoint novo
à internet, é sempre o cluster **puxando** informação do GitHub, nunca o
GitHub entrando no cluster. Pra uma demo, o atraso do intervalo de polling
é irrelevante; o trade-off só compensaria trocar se algum dia precisar de
disparo instantâneo de verdade.

Um bug real que apareci enquanto testava esse poller: o próprio commit que
o pipeline faz no `values.yaml` (bump de tag) era detectado como "mudança
nova" no polling seguinte, disparando outro build, que fazia outro commit,
que disparava outro poll — um loop de auto-disparo (vi dezenas de
`git-triggered-build-*` rodando sozinhas por horas). A correção foi filtrar
explicitamente: só considero "mudança de verdade" se o diff entre os dois
SHAs tiver algum arquivo sob `apps/` **além** do próprio
`apps/springboot/values.yaml`.

## O desafio extra: promoção automática via CloudWatch Alarm

A proposta do desafio extra era: depois que a shard-1 chegasse a 100%, o
pipeline devia consultar um alarme do CloudWatch — se `OK`, promove a
shard-2 sozinho; se `ALARM`/`INSUFFICIENT_DATA`, faz rollback da shard-1.

Em vez de escolher entre "sempre manual" ou "sempre automático" na hora de
aplicar o Terraform, resolvi deixar isso como um **toggle em tempo de
execução**, lido direto do `values.yaml`:

```yaml
# apps/springboot/values.yaml
promotion:
  automaticApproval: false   # true = automático (CloudWatch) / false = manual (suspend)
  cloudWatchAlarmName: "eks-automode-dev-springboot-shard1-health"
```

Trocar de modo vira só um commit — nenhum `terraform apply` novo. Pra isso
funcionar, precisei reestruturar o template principal do `steps:`
sequencial que eu tinha pra um `dag:`: a partir do momento em que a shard-1
fica `Healthy`, o fluxo se ramifica (checa o alarme OU espera aprovação
manual, dependendo do toggle) e depois converge de volta num único passo de
promoção.

A parte mais delicada foi a lógica de convergência: como só uma das duas
ramificações realmente roda (a outra fica `Skipped`, dependendo do
`when`), o `depends` do passo de convergência precisou considerar as duas
possibilidades — `Succeeded` **ou** `Skipped` — pros dois lados. Registrei
isso explicitamente no código como um ponto de atenção: a lógica segue a
documentação do Argo Workflows, mas eu não validei os três cenários
(automático+OK, automático+ALARM, manual) rodando de ponta a ponta ainda.

Pra testar sem depender de nenhuma métrica de verdade publicada, criei um
alarme de teste (`cloudwatch-alarm.tf`, `treat_missing_data = "breaching"`
— ou seja, sem dado nenhum ele já bloqueia por padrão, nunca promove "por
acidente") e forço o estado manualmente:

```bash
aws cloudwatch set-alarm-state \
  --alarm-name eks-automode-dev-springboot-shard1-health \
  --state-value OK \
  --state-reason "teste manual" \
  --region us-east-1
```

## Os perrengues que mais me custaram tempo

Vale registrar os que não eram óbvios de antemão:

**Nodes que nunca se registravam no cluster.** Depois de aplicar a infra, o
pod do Argo Workflows ficava `Pending` pra sempre — o Karpenter criava o
`NodeClaim`, a EC2 subia, mas o node nunca aparecia no cluster
(`Registered=Unknown`, "Node not registered with cluster"). Rastreei até a
VPC: as subnets públicas não tinham `map_public_ip_on_launch = true`, e o
endpoint do cluster é só público (`endpointPrivateAccess = false`) — um
node sem IP público numa subnet pública tem rota de saída pro Internet
Gateway, mas nenhum jeito de completar a conexão de volta pro control
plane. Corrigi isso direto no módulo da VPC (`terraform/infra/vpc.tf`).

**Tag imutável no ECR bloqueando reruns.** O repositório ECR é
`IMMUTABLE` — rodar o pipeline duas vezes pro mesmo commit falha no push
porque a tag já existe. É proteção, não bug (evita sobrescrever uma imagem
já publicada), mas atrapalha testar o mesmo commit de novo — criei
`scripts/04-delete-ecr-images.sh` pra limpar o repositório antes de um
`terraform destroy`/re-teste.

**StorageClass que o Auto Mode não cria sozinho.** O `WorkflowTemplate`
precisa de um PVC pra compartilhar o clone do repositório entre os passos
(cada passo do Argo Workflows roda num pod separado — um `emptyDir` não
sobrevive entre eles). A `StorageClass` `gp2` que já vem em qualquer
cluster EKS usa um provisioner legado que não roda no Auto Mode — o volume
ficava preso pra sempre em `Pending`. O Auto Mode usa um provisioner
próprio (`ebs.csi.eks.amazonaws.com`, com "eks" no meio), e — ao contrário
do que a documentação de "block storage capability" sugere — não cria
nenhuma `StorageClass` sozinho; precisei criar a minha
(`terraform/platform/storageclass.tf`).

**RBAC de subresource é RBAC à parte.** Pro passo de rollback conseguir
abortar um `Rollout` via `kubectl patch ... --subresource status`, dar
`get`/`list`/`watch` no recurso `rollouts` não bastou — precisei de uma
`rule` **separada** pro subresource `rollouts/status`. Subresources do
Kubernetes têm RBAC independente do recurso "pai", mesmo sendo o mesmo
objeto.

**O botão "Resume" não está onde parece.** Testando o gate manual de
aprovação, não achava o botão de resumir um Workflow suspenso — ele fica na
barra do **topo da tela do workflow** (ao lado de Retry/Terminate), não
dentro do card do node suspenso. Fica de aprendizado pra quem for repetir:
clique no node primeiro pra esse botão aparecer.

## Decisões que assumi conscientemente (trade-offs)

Nem tudo que fica funcionando é a escolha "certa" em produção — algumas
coisas eu decidi deliberadamente pra manter o escopo de uma demo/teste
técnico:

- **NLBs públicos (`internet-facing`) pro ArgoCD, Argo Workflows e as
  apps.** Combinado com `--auth-mode=server` no Argo Workflows (UI sem
  exigir login), isso significa que qualquer pessoa com o hostname
  consegue não só visualizar, mas **disparar/abortar** workflows sem
  autenticação. Aceitável pra um teste de curta duração; numa situação real
  eu trocaria pra `internal` ou colocaria atrás de VPN/bastion.
- **Um único NAT Gateway** (`single_nat_gateway = true`) em vez de um por
  AZ — mais barato, mas se a AZ onde ele está cair, as subnets privadas nas
  outras AZs perdem saída pra internet até ela voltar. Pra produção, eu
  desligaria essa flag.
- **Sem progressão automática cronometrada** nem no Canary Deploy
  (`pause: { duration: ... }`) nem entre shards (o ArgoCD tem um recurso
  nativo pra isso, `Progressive Syncs`/`RollingSync`) — o requisito pedia
  aprovação manual explícita nos dois níveis, então não usei nenhum dos
  dois de propósito.
- **Repositório GitHub público** — o Secret que permitiria o ArgoCD clonar
  um repositório privado (`argocd-github-secret.tf`) está no código, mas
  comentado. Pra reativar, é só descomentar (reaproveita as mesmas
  variáveis já usadas pelo Argo Workflow).

## Como rodar você mesmo

Pré-requisitos: Terraform >= 1.4.4, AWS CLI configurado, Helm >= 3.8
(usado internamente pelo provider), permissões IAM pra criar VPC/EKS/IAM
Roles/ECR, `kubectl` + [plugin do Argo Rollouts](https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation),
opcionalmente o [Argo Workflows CLI](https://argo-workflows.readthedocs.io/en/latest/walk-through/argo-cli/)
e o [ArgoCD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/),
e um Personal Access Token do GitHub (escopo `repo`) pro Argo Workflow
conseguir dar `git push` de volta no repositório.

```bash
# Etapa 1 — infraestrutura AWS (VPC, IAM, cluster EKS, ECR)
cd terraform/infra
terraform init
terraform apply -var-file=environment/dev/terraform.tfvars

# Etapa 2 — NodePools, ArgoCD, Argo Rollouts, Argo Workflows, Project e ApplicationSet
cd ../platform
cp environment/dev/secrets.tfvars.example environment/dev/secrets.tfvars
# edite environment/dev/secrets.tfvars com seu github_username/github_token
terraform init
terraform apply \
  -var-file=environment/dev/terraform.tfvars \
  -var-file=environment/dev/secrets.tfvars
```

O passo a passo completo — com todos os comandos, o que esperar em cada
etapa e como reconhecer/resolver os problemas mais comuns (incluindo os que
descrevi acima) — está em `TESTE-END-TO-END.md`.

### Como destruir

Ordem inversa: `platform` primeiro (o cluster precisa continuar de pé pro
Terraform remover graciosamente os recursos Kubernetes/Helm), `infra`
depois:

```bash
cd terraform/platform
terraform destroy \
  -var-file=environment/dev/terraform.tfvars \
  -var-file=environment/dev/secrets.tfvars

cd ../infra
terraform destroy -var-file=environment/dev/terraform.tfvars
```

## O que eu ainda quero arrumar

Ficam anotados aqui pra não esquecer (e pra ser honesto sobre o estado
atual do projeto, caso alguém vá reproduzir):

- `terraform/infra/locals.tf` duplica um cálculo que só é usado em
  `terraform/platform` — virou código morto em `infra` depois que dividi o
  projeto em duas camadas. Ainda não limpei.
- A lógica de convergência do DAG de promoção automática/manual (ver acima)
  não foi validada rodando os três cenários de ponta a ponta.
- O nome do `Service` do ArgoCD Server é assumido como `argocd-server` em
  `outputs.tf` — funcionou na versão do chart que usei, mas não é 100%
  garantido por todas as versões.
- Pra produção de verdade: múltiplos NAT Gateways, backend remoto (S3 +
  DynamoDB) pro state de cada camada, exposição via Ingress/ALB com TLS em
  vez de NLB direto, HA no ArgoCD (`redis-ha.enabled`), e trocar o polling
  do Argo Workflows por um webhook (Argo Events) se precisar de disparo
  instantâneo.

## Fechando

O maior aprendizado técnico desse projeto pra mim foi como cada camada do
EKS Auto Mode (rede, storage, load balancer, RBAC) tem uma convenção
própria e ligeiramente diferente do EKS "clássico" — e boa parte do tempo
não foi escrever o Terraform em si, foi debugar por que um componente que
"deveria simplesmente funcionar" ficava preso esperando algo que eu nem
sabia que precisava declarar explicitamente (a `StorageClass`, o
`map_public_ip_on_launch`, o RBAC de subresource). Deixei essas histórias
no texto de propósito — se você estiver implementando algo parecido, é bem
provável que bata numa delas.

O código completo está neste repositório; o passo a passo operacional
detalhado (comandos exatos, o que esperar em cada tela) está em
`TESTE-END-TO-END.md`.
