Coloque aqui (NÃO versionar):

  tls.crt  -> certificado do servidor + intermediárias (PEM, nesta ordem)
  tls.key  -> chave privada PEM sem senha

Os nomes são os mesmos de um Secret Kubernetes do tipo kubernetes.io/tls:
  kubectl create secret tls wcb-tls --cert=tls.crt --key=tls.key -n <namespace>
