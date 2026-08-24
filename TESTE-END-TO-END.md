# Teste fim a fim

Passo a passo para validar o fluxo completo: provisionar tudo do zero,
disparar o Argo Workflow (automaticamente, via polling do Git, ou
manualmente — este runbook usa o disparo manual pra não depender de
esperar o próximo ciclo de polling), acompanhar o canário na shard 1,
aprovar manualmente a promoção para a shard 2, e confirmar que o isolamento
físico das shards funciona de verdade. Os comandos assumem os valores
padrão de
`environment/dev` (`cluster_name = eks-automode-dev`, `aws_region =
us-east-1`, `ecr_repository_name = eks-automode-app-dev`) — ajuste se você
mudou algo.

Cada seção tem os comandos e, logo abaixo, o que esperar ver — se o
resultado for diferente do esperado, é sinal de algo errado antes de seguir
para o próximo passo.

## 0. Pré-requisitos

Confirme que as ferramentas necessárias estão instaladas e autenticadas
antes de começar:


```bash
terraform -version   # >= 1.4.4
aws sts get-caller-identity   # credenciais AWS válidas
kubectl version --client
helm version
kubectl argo rollouts version   # plugin do Argo Rollouts
argocd version --client
argo version   # CLI do Argo Workflows
git --version
```

**Esperado:** todos retornam versão, sem erro de "command not found" ou de
credenciais. Se `aws sts get-caller-identity` falhar, resolva isso antes de
tudo (`aws configure` ou variáveis `AWS_*`).

## 1. Provisionar a camada `infra`

```bash
cd terraform/infra
terraform init
terraform apply -var-file=environment/dev/terraform.tfvars
```

Digite `yes` quando pedido. Isso demora uns 10-15 min (o cluster EKS é o
que mais demora).

**Esperado:** `Apply complete!` no final, sem erros. Anote a saída de
`ecr_repository_url` (vai aparecer nos outputs) — deve ser algo como
`123456789012.dkr.ecr.us-east-1.amazonaws.com/eks-automode-app-dev`.

Confirme o cluster:

```bash
aws eks describe-cluster --name eks-automode-dev --region us-east-1 \
  --query "cluster.status"
```

**Esperado:** `"ACTIVE"`.

## 2. Provisionar a camada `platform`

```bash
cd ../platform
cp environment/dev/secrets.tfvars.example environment/dev/secrets.tfvars
```

Edite `environment/dev/secrets.tfvars` e preencha:

```hcl
github_username = "<seu-usuario-github>"
github_token     = "<seu-personal-access-token-com-escopo-repo>"
```

Confirme também que `environment/dev/terraform.tfvars` tem
`github_repo_url` apontando para **este** repositório (o que contém
`apps/springboot`) — sem isso o Argo Workflow não vai conseguir clonar nem
dar push no lugar certo.

```bash
terraform init
terraform apply \
  -var-file=environment/dev/terraform.tfvars \
  -var-file=environment/dev/secrets.tfvars
```

Digite `yes` quando pedido.

**Esperado:** `Apply complete!`. Se o Terraform parar pedindo
`var.github_username`/`var.github_token` interativamente, o
`secrets.tfvars` não foi encontrado ou não foi passado no comando — confira
o passo acima.

## 3. Configurar o `kubectl` e checar a instalação de base

```bash
aws eks update-kubeconfig --region us-east-1 --name eks-automode-dev
kubectl get nodepools
kubectl get nodeclasses
kubectl get ns
```

**Esperado:**
- `nodepools`: `shard-1` e `shard-2` listados.
- `nodeclasses`: `shard-1` e `shard-2` listados.
- `ns`: `argocd`, `argo-rollouts` e `argo-workflows` presentes (além dos
  namespaces padrão do cluster). Os namespaces `shard-1`/`shard-2` da
  aplicação só aparecem depois do primeiro sync do ArgoCD (próximo passo).

```bash
kubectl get pods -n argocd
kubectl get pods -n argo-rollouts
kubectl get pods -n argo-workflows
```

**Esperado:** todos os pods em `Running`/`Completed`, sem `CrashLoopBackOff`.
Se algum estiver `Pending` há muito tempo, os nodes do Auto Mode ainda
podem estar subindo (Karpenter demora 1-2 min para provisionar a primeira
instância) — aguarde e rode de novo.

## 4. Checar o estado inicial das duas Applications no ArgoCD

```bash
kubectl get applications -n argocd
```

**Esperado:** `springboot-shard-1` e `springboot-shard-2` listadas. Nesse
ponto, **antes** do primeiro build, `apps/springboot/values.yaml` ainda tem
o `image.repository` placeholder (`CHANGE-ME...`) — é normal a
`springboot-shard-1` (que sincroniza sozinha) estar `Synced` mas
`Degraded`/`Progressing` com os pods em `ErrImagePull`/`ImagePullBackOff`.
Isso se resolve no próximo passo, quando o Argo Workflow corrige a imagem.

Acesse a UI do ArgoCD para acompanhar visualmente (opcional, mas útil):

```bash
kubectl port-forward svc/argocd-argocd-server -n argocd 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

Abra https://localhost:8080, login `admin` + a senha impressa acima.

## 5. Disparar o Argo Workflow (build + push + atualização do Git)

Desde `argoworkflows-poller.tf`, isso acontece **sozinho**: um
`CronWorkflow` (`git-poll-trigger`) roda a cada 2 min, detecta que o Git
mudou e dispara o build automaticamente — não seria necessário rodar nada
aqui. Mas para este teste guiado, dispare manualmente pra não depender de
esperar até 2 min pelo próximo ciclo de polling:

```bash
argo submit --from workflowtemplate/build-push-springboot \
  -n argo-workflows --watch
```

(Se quiser confirmar o disparo automático em vez do manual, pule este
comando e espere até 2 min — depois rode `argo list -n argo-workflows` e
veja um Workflow novo com o prefixo `git-triggered-build-` aparecer
sozinho.)

Acompanhe os 4 passos no terminal (`clone-repo` → `maven-build` →
`kaniko-build-push` → `update-values`). Isso demora uns 3-5 min (o build
Maven e o download das camadas base do Kaniko são a parte mais lenta na
primeira execução).

**Esperado:** ao final, o Workflow aparece como `Succeeded`. Se algum passo
falhar, veja os logs dele especificamente:

```bash
argo logs @latest -n argo-workflows
```

Causas comuns de falha: `git push` rejeitado (verifique
`github_username`/`github_token` no Secret — veja passo 5.1 abaixo) ou
Kaniko sem permissão no ECR (verifique se a role IRSA foi criada — passo
5.2 abaixo).

### 5.1 Se o `update-values` falhar no `git push`

```bash
kubectl get secret git-push-credentials -n argo-workflows -o yaml
```

**Esperado:** os campos `data.username`/`data.token` existem (em base64).
Se o token expirou ou foi revogado, gere um novo em
https://github.com/settings/tokens, atualize `secrets.tfvars` e rode
`terraform apply` de novo na camada `platform` (o Secret é recriado com o
valor novo).

### 5.2 Se o `kaniko-build-push` falhar por permissão no ECR

```bash
kubectl get sa argo-workflow-ecr-push -n argo-workflows -o yaml \
  | grep role-arn
aws iam get-role --role-name eks-automode-dev-argo-workflow-ecr-push
```

**Esperado:** a ServiceAccount tem a annotation `eks.amazonaws.com/role-arn`
apontando para a role, e a role existe na conta.

## 6. Confirmar a imagem no ECR e o commit no Git

```bash
aws ecr describe-images --repository-name eks-automode-app-dev \
  --region us-east-1 --query "imageDetails[].imageTags"
```

**Esperado:** uma tag nova, com 7 caracteres (o commit SHA curto) — algo
como `["a1b2c3d"]`.

```bash
git pull
cat apps/springboot/values.yaml
```

**Esperado:** `image.repository` agora aponta para o ECR real (não mais
`CHANGE-ME...`), `image.tag` é a mesma tag do ECR acima, e existe um commit
novo no histórico com a mensagem `Commit: bump image to <tag>
[argo-workflows]`:

```bash
git log --oneline -3
```

## 7. Acompanhar e promover manualmente o canário na shard 1

```bash
kubectl get applications -n argocd
```

**Esperado:** `springboot-shard-1` muda para `Synced`/`Healthy` em alguns
segundos/minutos (o ArgoCD faz polling do Git a cada ~3 min por padrão —
force um refresh se não quiser esperar: `argocd app sync
springboot-shard-1` ou `argocd app get springboot-shard-1 --refresh`).

```bash
kubectl argo rollouts get rollout springboot -n shard-1 --watch
```

**Esperado:** o rollout passa por `SetWeight(50)` e **fica parado em
`Paused`** — o `pause` não tem `duration`, então o Argo Rollouts **não
promove sozinho**. É preciso aprovar manualmente:

```bash
kubectl argo rollouts promote springboot -n shard-1
```

**Esperado:** o rollout continua e chega em `SetWeight(100)` →
`Healthy`.

```bash
kubectl get pods -n shard-1 -o wide
```

**Esperado:** os pods da app rodando em nodes com o label `shard=shard-1`.
Confirme:

```bash
kubectl get pods -n shard-1 -o jsonpath='{.items[0].spec.nodeName}'
kubectl get node <nome-do-node-acima> --show-labels | grep shard
```

## 8. Testar a resposta da aplicação na shard 1

```bash
kubectl port-forward svc/springboot-stable -n shard-1 8081:80
```

Em outro terminal:

```bash
curl http://localhost:8081/
# {"application":"springboot-sharded-app","version":"...","shard":"shard-1"}
curl http://localhost:8081/health
```

**Esperado:** `shard` no JSON é `"shard-1"` e `version` bate com o que está
em `apps/springboot/values.yaml`/`pom.xml`.

## 9. Confirmar que a shard 2 está aguardando aprovação manual

```bash
kubectl get applications -n argocd
argocd app get springboot-shard-2
```

**Esperado:** `springboot-shard-2` aparece como `OutOfSync` — ela **não**
sincronizou sozinha, mesmo com a shard 1 já saudável. Isso é o gate manual
funcionando.

## 10. Aprovar manualmente a promoção para a shard 2

```bash
argocd app sync springboot-shard-2
```

Se não tiver o ArgoCD CLI configurado (login feito), use o fallback via
`kubectl`:

```bash
kubectl patch application springboot-shard-2 -n argocd --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

**Esperado:** `springboot-shard-2` muda para `Syncing` e depois
`Synced`/`Healthy`.

## 11. Acompanhar e promover manualmente o canário (independente) na shard 2

```bash
kubectl argo rollouts get rollout springboot -n shard-2 --watch
```

**Esperado:** o mesmo padrão da shard 1 — `SetWeight(50)` e **fica parado
em `Paused`**, rodando de forma **independente** do rollout da shard 1 (já
concluído). Aprove manualmente:

```bash
kubectl argo rollouts promote springboot -n shard-2
```

**Esperado:** o rollout continua e chega em `SetWeight(100)` → `Healthy`.

```bash
kubectl port-forward svc/springboot-stable -n shard-2 8082:80
curl http://localhost:8082/
# shard deve ser "shard-2"
```

## 12. Validar o isolamento físico entre as shards (taint)

Tente agendar um pod qualquer, sem toleration, com `nodeSelector` forçando
um node da shard 1 — ele deve ficar `Pending` por causa do taint:

```bash
kubectl run teste-isolamento --image=busybox --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"shard":"shard-1"},"containers":[{"name":"teste-isolamento","image":"busybox","command":["sleep","3600"]}]}}'

kubectl get pod teste-isolamento -o wide
kubectl describe pod teste-isolamento | grep -A5 Events
```

**Esperado:** o pod fica `Pending` e o `describe` mostra um evento do tipo
`FailedScheduling` mencionando o taint `shard=shard-1:NoSchedule` — prova
que só pods com a toleration certa (como o `Rollout` da app) conseguem
rodar nesses nodes.

Limpe o pod de teste:

```bash
kubectl delete pod teste-isolamento
```

## 13. Teste de round-trip completo (uma mudança real de código)

Simule uma alteração real na aplicação, do jeito que aconteceria na prática:

```bash
# edite algo simples, ex.: a versão em apps/pom.xml ou uma mensagem em
# ApplicationController.java
git add -A
git commit -m "teste: valida pipeline fim a fim"
git push
```

Desta vez **não dispare manualmente** — esse é o teste do disparo
automático. Espere até 2 min (o intervalo do `CronWorkflow` de polling) e
confirme que um Workflow novo apareceu sozinho:

```bash
kubectl get cronworkflow git-poll-trigger -n argo-workflows
argo list -n argo-workflows
```

**Esperado:** um `Workflow` novo com o prefixo `git-triggered-build-`
(diferente do nome que `argo submit` gera) aparece sozinho, sem você ter
rodado nenhum comando de disparo. Se quiser ver os logs do próprio
`CronWorkflow` decidindo disparar:

```bash
kubectl get configmap git-poll-state -n argo-workflows -o jsonpath='{.data.last-sha}'; echo
argo logs @latest -n argo-workflows -c check-repo
```

Se depois de uns 3 minutos nenhum Workflow novo apareceu, dispare
manualmente pra não travar o teste e investigue o `CronWorkflow` depois:

```bash
argo submit --from workflowtemplate/build-push-springboot \
  -n argo-workflows --watch
```

**Esperado (de qualquer forma):** uma tag de imagem **nova** (novo commit
SHA), a `springboot-shard-1` sincroniza sozinha e o canário pausa em 50%
aguardando `kubectl argo rollouts promote`, e a `springboot-shard-2` volta
a ficar `OutOfSync` aguardando uma nova aprovação manual — repita os passos
7 a 11 para confirmar (lembrando de promover manualmente o canário em cada
shard).

## 14. (Opcional) Abortar/reiniciar um canário durante o teste

Se quiser testar o comportamento de rollback:

```bash
kubectl argo rollouts abort springboot -n shard-1
kubectl argo rollouts get rollout springboot -n shard-1 --watch
```

**Esperado:** o rollout marca o passo atual como abortado e volta 100% do
tráfego para a versão anterior (`stable`). Para tentar de novo do zero:

```bash
kubectl argo rollouts retry rollout springboot -n shard-1
```

## 15. Encerrar o teste

Se for só uma pausa, não precisa destruir nada — o ambiente fica de pé.
Para desmontar tudo ao final (ordem inversa da criação, veja o README para
detalhes):

```bash
cd terraform/platform
terraform destroy \
  -var-file=environment/dev/terraform.tfvars \
  -var-file=environment/dev/secrets.tfvars

cd ../infra
terraform destroy -var-file=environment/dev/terraform.tfvars
```

## Checklist resumido

- [ ] `infra` aplicado sem erro, cluster `ACTIVE`
- [ ] `platform` aplicado sem erro (com `secrets.tfvars`)
- [ ] NodePools/NodeClasses `shard-1`/`shard-2` existem
- [ ] Pods de `argocd`/`argo-rollouts`/`argo-workflows` rodando
- [ ] `argo submit` do `build-push-springboot` termina `Succeeded`
- [ ] Nova tag no ECR + `values.yaml` atualizado + commit novo no Git
- [ ] `springboot-shard-1` sincroniza sozinha e o canário pausa em 50% (`Paused`)
- [ ] `kubectl argo rollouts promote springboot -n shard-1` leva o canário a 100%
- [ ] App na shard 1 responde com `"shard":"shard-1"`
- [ ] `springboot-shard-2` fica `OutOfSync` até aprovação manual
- [ ] `argocd app sync springboot-shard-2` promove a Application e o canário roda de novo, pausando em 50%
- [ ] `kubectl argo rollouts promote springboot -n shard-2` leva o canário a 100%
- [ ] App na shard 2 responde com `"shard":"shard-2"`
- [ ] Pod sem toleration fica `Pending` em node da shard (taint funcionando)
- [ ] Round-trip completo (novo commit → novo build → novo canário) funciona
- [ ] `git-poll-trigger` (CronWorkflow) dispara sozinho um `git-triggered-build-*` sem `argo submit` manual

## Apêndice A: Testar a app localmente, sem o cluster

Útil pra desenvolver/testar a app antes de subir qualquer infra na AWS:

```bash
cd apps
mvn spring-boot:run
# ou: mvn clean package -DskipTests && java -jar target/springboot-sharded-app-1.0.0.jar
```

Em outro terminal:

```bash
curl http://localhost:8080/
# {"application":"springboot-sharded-app","version":"1.0.0","shard":"unknown"}
curl http://localhost:8080/health
curl http://localhost:8080/actuator/health/readiness
```

**Esperado:** os três respondem sem erro. `shard` aparece como `"unknown"`
porque `APP_SHARD` só é definida como env var dentro do `Rollout`
(`apps/springboot/templates/rollout.yaml`) — localmente essa variável não
existe.

## Apêndice B: Acessar ArgoCD/Argo Workflows via NLB (hostname público/interno)

Alternativa ao `port-forward` usado nas seções acima — útil se quiser
acessar sem manter um túnel aberto. O provisionamento do NLB é
**assíncrono**: nos primeiros minutos depois do `apply`, o hostname pode
ainda não existir.

ArgoCD:

```bash
kubectl get svc -n argocd argocd-argocd-server
```

Ou use `scripts/02-get-argocd-lb-address-and-password.sh` (imprime a senha
inicial do admin e a URL — assume um binário `jq` no PATH chamado
`jq-windows-amd64.exe`, ajuste se necessário).

Argo Workflows:

```bash
kubectl get svc -n argo-workflows argo-workflows-server
```

**Esperado:** o campo `EXTERNAL-IP` (ou `LoadBalancer Ingress` num
`kubectl describe svc`) mostra um hostname `*.elb.amazonaws.com` depois de
alguns minutos. A UI do Argo Workflows usa HTTPS com certificado
autoassinado por padrão — o navegador vai avisar, é esperado (aceite o
risco/prossiga). Veja no README, seções "Expondo o ArgoCD/Argo Workflows
via LoadBalancer", o significado de cada annotation e os avisos de
segurança sobre deixar esses NLBs públicos.

## Apêndice C: Build e push manual da imagem, sem o Argo Workflow

Alternativa mais rápida ao pipeline completo de 4 passos — útil pra testar
uma mudança pontual:

```bash
# Linux/macOS
./scripts/build-push.sh 1.0.1

# Windows
./scripts/build-push.ps1 -Tag 1.0.1
```

Sobrescreva `ECR_REPOSITORY`/`AWS_REGION` (bash) ou `-Repository`/`-Region`
(PowerShell) se o seu ambiente usar outro nome/região.

⚠️ O repositório ECR é criado com `image_tag_mutability = IMMUTABLE`: cada
push precisa de uma tag **nova** (ex.: `1.0.1`, `1.0.2`...) — tentar
sobrescrever uma tag já publicada falha, por design.

**Importante:** diferente do Argo Workflow, esse script **não** atualiza
`apps/springboot/values.yaml` nem dá `git commit`/`push`. Pra disparar o
deploy gradual com essa imagem, edite `image.tag`/`image.repository` em
`apps/springboot/values.yaml` manualmente e dê commit/push você mesmo —
depois disso o fluxo é o mesmo das seções 7 a 11 acima.

## Apêndice D: Ver logs do control plane

```bash
aws logs tail /aws/eks/eks-automode-dev/cluster --follow
```

**Esperado:** eventos de log dos 5 tipos habilitados (`api`, `audit`,
`authenticator`, `controllerManager`, `scheduler`). Isso cobre só o
**control plane** — não mostra logs de aplicação (stdout dos pods).
