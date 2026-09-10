{
  mkKubeconfig =
    {
      ca,
      server,
      clusterName,
      userName,
      contextName ? clusterName,
      certFile,
      keyFile,
    }:
    ''
      apiVersion: v1
      kind: Config
      clusters:
      - cluster:
          certificate-authority: ${ca}
          server: ${server}
        name: ${clusterName}
      contexts:
      - context:
          cluster: ${clusterName}
          user: ${userName}
        name: ${contextName}
      current-context: ${contextName}
      users:
      - name: ${userName}
        user:
          client-certificate: ${certFile}
          client-key: ${keyFile}
    '';
}
