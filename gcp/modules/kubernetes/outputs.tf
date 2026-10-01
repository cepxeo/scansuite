output "web_neg_name" {
  value = local.web_neg
}

output "namespace" {
  value = kubernetes_namespace_v1.this.metadata[0].name
}

output "workloads" {
  description = "Handle for depends_on - the NEG only exists once the Service and its pods do."
  value = [
    kubernetes_service_v1.web.id,
    kubernetes_deployment_v1.web.id,
    kubernetes_stateful_set_v1.scan_engine.id,
  ]
}
