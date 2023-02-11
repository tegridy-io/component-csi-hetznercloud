// main template for csi-hetznercloud
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local sc = import 'lib/storageclass.libsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.csi_hetznercloud;
local isOpenshift = std.startsWith(inv.parameters.facts.distribution, 'openshift');

local namespace = kube.Namespace(params.namespace) {
  metadata+: {
    labels+: {
      'app.kubernetes.io/name': params.namespace,
      'pod-security.kubernetes.io/enforce': 'privileged',
      // Configure the namespaces so that the OCP4 cluster-monitoring
      // Prometheus can find the servicemonitors and rules.
      [if isOpenshift then 'openshift.io/cluster-monitoring']: 'true',
    },
  },
};

local hcloudToken = kube.Secret('hcloud') {
  stringData: {
    token: params.hcloudToken,
  },
};

local storageClass = sc.storageClass('hcloud-volumes') {
  allowVolumeExpansion: true,
  provisioner: 'csi.hetzner.cloud',
  volumeBindingMode: 'WaitForFirstConsumer',
};

// Define outputs below
{
  '00_namespace': namespace,
  '20_hcloud_token': hcloudToken,
  '30_storage_class': storageClass,
}
