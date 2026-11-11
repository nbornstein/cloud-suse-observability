output "observability_url" {
  description = "URL for the SUSE Observability UI"
  value       = "https://${local.observability_hostname}"
}

output "receiver_url" {
  description = "URL agents should report data to (SUSE Observability's /receiver endpoint)"
  value       = "https://${local.observability_hostname}/receiver"
}

output "load_balancer_public_ip" {
  description = "Public IP address of the cloud load balancer fronting the RKE2 cluster"
  value       = local.lb_public_ip
}

output "cluster_node_public_ips" {
  description = "Public IP addresses of the RKE2 cluster nodes, in node order (node 1 runs SUSE Observability's Helm install)"
  value       = local.cluster_node_public_ips
}

output "ssh_connection_commands" {
  description = "Ready-to-use SSH commands for each cluster node"
  value       = [for ip in local.cluster_node_public_ips : "ssh ${local.admin_username}@${ip}"]
}

output "kubeconfig_fetch_command" {
  description = "Command to retrieve the kubeconfig from the first node (rewrite the server address to the load balancer IP before using it remotely)"
  value       = "ssh ${local.admin_username}@${local.cluster_node_public_ips[0]} sudo cat /etc/rancher/rke2/rke2.yaml"
}
