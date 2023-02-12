// main template for cm-hetznercloud
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.csi_hetznercloud;

local csiDriver = com.Kustomization(
  'https://github.com/hetznercloud/csi-driver//deploy/kubernetes',
  params.manifestVersion,
  {
    'hetznercloud/hcloud-csi-driver': {
      newTag: params.images.csi_driver.tag,
      newName: '%(registry)s/%(repository)s' % params.images.csi_driver,
    },
    'k8s.gcr.io/sig-storage/csi-attacher': {
      newTag: params.images.csi_attacher.tag,
      newName: '%(registry)s/%(repository)s' % params.images.csi_attacher,
    },
    'k8s.gcr.io/sig-storage/csi-resizer': {
      newTag: params.images.csi_resizer.tag,
      newName: '%(registry)s/%(repository)s' % params.images.csi_resizer,
    },
    'k8s.gcr.io/sig-storage/csi-provisioner': {
      newTag: params.images.csi_provisioner.tag,
      newName: '%(registry)s/%(repository)s' % params.images.csi_provisioner,
    },
    'k8s.gcr.io/sig-storage/csi-node-driver-registrar': {
      newTag: params.images.csi_registrar.tag,
      newName: '%(registry)s/%(repository)s' % params.images.csi_registrar,
    },
    'k8s.gcr.io/sig-storage/livenessprobe': {
      newTag: params.images.liveness_probe.tag,
      newName: '%(registry)s/%(repository)s' % params.images.liveness_probe,
    },
  },
  {
    patchesStrategicMerge: [
      'rm-storageclass.yaml',
    ],
  } + com.makeMergeable(params.kustomizeInput),
) {
  'rm-storageclass': {
    '$patch': 'delete',
    apiVersion: 'storage.k8s.io/v1',
    kind: 'StorageClass',
    metadata: {
      annotations: {
        'storageclass.kubernetes.io/is-default-class': 'true',
      },
      name: 'hcloud-volumes',
    },
  },
};

csiDriver
