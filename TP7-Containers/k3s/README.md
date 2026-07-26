# ☸️ k3s / k3d — notes et outillage

Compléments à la partie Kubernetes du [TP7](../README.md).

---

## 📄 Manifestes fournis

| Fichier | Contenu |
|---|---|
| [`nginx-manifest.yaml`](nginx-manifest.yaml) | Deployment + Service + Ingress nginx |
| [`pyapp.yml`](pyapp.yml) | Deployment (3 réplicas) + Service + Ingress pour PyApp, dans le namespace `pyapp` |

> ⚠️ **Ces deux manifestes datent de Kubernetes 1.18** et doivent être adaptés :
> - `apiVersion: extensions/v1beta1` pour l'Ingress → **supprimée en Kubernetes 1.22**.
>   Utiliser `networking.k8s.io/v1` (avec `pathType` et la nouvelle structure `backend.service`).
> - `pyapp.yml` référence le namespace `pyapp` sans le créer :
>   `kubectl create namespace pyapp` au préalable.
> - Les images `docker.ntl.nc/...` proviennent d'un registre interne : remplacez-les ou
>   importez-les dans le cluster avec `k3d image import`.

---

## 🔧 Kubeconfig

k3d configure `kubectl` automatiquement à la création du cluster. Pour récupérer ou exporter
la configuration manuellement :

```bash
# Écrit la config dans ~/.kube/config et bascule le contexte
k3d kubeconfig merge dev --kubeconfig-switch-context

# Ou l'écrire dans un fichier dédié
k3d kubeconfig get dev > /tmp/kubeconfig-dev
export KUBECONFIG=/tmp/kubeconfig-dev

kubectl config get-contexts
kubectl get nodes
```

> ⚠️ L'ancienne commande `k3d get-kubeconfig --name='dev'` (k3d v1) n'existe plus.

Avec **k3s installé directement sur l'hôte** (sans Docker) :

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# Ou, pour un utilisateur non-root :
mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$USER:$USER" ~/.kube/config
```

---

## 🧰 Outils utiles

### kubetail — agréger les logs de plusieurs pods

```bash
wget https://raw.githubusercontent.com/johanhaleby/kubetail/master/kubetail
chmod +x kubetail && sudo mv kubetail /usr/local/bin/

kubetail nginx
kubetail -l app=pyapp
```

> 💡 `kubectl` sait le faire nativement depuis longtemps — plus besoin d'outil externe :
> ```bash
> kubectl logs -f -l app=nginx --all-containers --max-log-requests=10
> ```

### k9s — interface TUI pour Kubernetes

```bash
K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r .tag_name)
wget "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz"
tar xzf k9s_Linux_amd64.tar.gz k9s && sudo mv k9s /usr/local/bin/
k9s
```

### Complétion et alias

```bash
# bash
echo 'source <(kubectl completion bash)' >> ~/.bashrc
# zsh
echo 'source <(kubectl completion zsh)' >> ~/.zshrc

echo 'alias k=kubectl' >> ~/.zshrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc
```

---

## 📋 Antisèche kubectl

```bash
# Consulter
kubectl get all -A                          # tout, tous namespaces
kubectl get pods -o wide                    # avec IP et nœud
kubectl describe pod NOM                    # 💡 la section "Events" en bas explique 90 % des pannes
kubectl logs NOM -f --tail=100
kubectl logs NOM --previous                 # logs du conteneur AVANT son crash

# Agir
kubectl apply -f fichier.yaml               # créer ou mettre à jour (idempotent)
kubectl delete -f fichier.yaml
kubectl exec -it NOM -- sh
kubectl port-forward svc/nginx 8080:80      # accès direct sans Ingress
kubectl scale deployment/nginx --replicas=3
kubectl rollout status deployment/nginx
kubectl rollout undo deployment/nginx

# Déboguer
kubectl get events -A --sort-by=.metadata.creationTimestamp | tail -20
kubectl top nodes && kubectl top pods       # nécessite metrics-server (inclus dans k3s)
kubectl api-resources                       # objets disponibles
kubectl explain ingress.spec.rules          # documentation d'un champ, en ligne de commande
```

---

## 🎯 Spécificités k3s

k3s embarque par défaut, sans installation supplémentaire :

| Composant | Rôle |
|---|---|
| **Traefik** | Ingress Controller (`ingressClassName: traefik`) |
| **ServiceLB (Klipper)** | Fournit des Services de type `LoadBalancer` sans cloud provider |
| **local-path-provisioner** | StorageClass par défaut, sur le disque local |
| **CoreDNS** | Résolution DNS interne |
| **metrics-server** | Alimente `kubectl top` |

```bash
kubectl get pods -n kube-system
kubectl get ingressclass
kubectl get storageclass
```

Désactiver un composant à l'installation :

```bash
curl -sfL https://get.k3s.io | sh -s - --disable traefik --disable servicelb
```

---

## 🧹 Nettoyage

```bash
# k3d
k3d cluster delete dev
k3d cluster list

# k3s installé sur l'hôte
/usr/local/bin/k3s-uninstall.sh          # serveur
/usr/local/bin/k3s-agent-uninstall.sh    # agent
```
