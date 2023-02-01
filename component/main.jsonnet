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


// Helpers

local Container(name, dir) = kube.Container(name) {
  local paramKey = std.strReplace(name, '-', '_'),
  image: '%(registry)s/%(repository)s:%(tag)s' % std.get(params.images, paramKey),
  resources: std.get(params.resources, paramKey),
  volumeMounts_:: {
    [dir]: { mountPath: '/run/csi' },
  },
};


// CSI Controller

local controlerName = 'hcloud-csi-controller';

local controlerServiceAccount = kube.ServiceAccount(controlerName) {
  metadata+: {
    namespace: params.namespace,
  },
};

local controlerClusterRole = kube.ClusterRole(controlerName) {
  rules: [
    { apiGroups: [ '*' ], resources: [ '*' ], verbs: [ '*' ] },
    { nonResourceURLs: [ '*' ], verbs: [ '*' ] },
    // attacher
    { apiGroups: [ '' ], resources: [ 'persistentvolumes' ], verbs: [ 'get', 'list', 'watch', 'update', 'patch' ] },
    { apiGroups: [ '' ], resources: [ 'nodes' ], verbs: [ 'get', 'list', 'watch' ] },
    { apiGroups: [ 'csi.storage.k8s.io' ], resources: [ 'csinodeinfos' ], verbs: [ 'get', 'list', 'watch' ] },
    { apiGroups: [ 'storage.k8s.io' ], resources: [ 'csinodes' ], verbs: [ 'get', 'list', 'watch' ] },
    { apiGroups: [ 'storage.k8s.io' ], resources: [ 'volumeattachments' ], verbs: [ 'get', 'list', 'watch', 'update', 'patch' ] },
    { apiGroups: [ 'storage.k8s.io' ], resources: [ 'volumeattachments/status' ], verbs: [ 'patch' ] },
    // provisioner
    { apiGroups: [ '' ], resources: [ 'secrets' ], verbs: [ 'get', 'list' ] },
    { apiGroups: [ '' ], resources: [ 'persistentvolumes' ], verbs: [ 'get', 'list', 'watch', 'create', 'delete', 'patch' ] },
    { apiGroups: [ '' ], resources: [ 'persistentvolumeclaims', 'persistentvolumeclaims/status' ], verbs: [ 'get', 'list', 'watch', 'update', 'patch' ] },
    { apiGroups: [ 'storage.k8s.io' ], resources: [ 'storageclasses' ], verbs: [ 'get', 'list', 'watch' ] },
    { apiGroups: [ '' ], resources: [ 'events' ], verbs: [ 'list, watch, create, update, patch' ] },
    { apiGroups: [ 'snapshot.storage.k8s.io' ], resources: [ 'volumesnapshots' ], verbs: [ 'get', 'list' ] },
    { apiGroups: [ 'snapshot.storage.k8s.io' ], resources: [ 'volumesnapshotcontents' ], verbs: [ 'get', 'list' ] },
    // resizer
    { apiGroups: [ '' ], resources: [ 'pods' ], verbs: [ 'get', 'list', 'watch' ] },
    // node
    { apiGroups: [ '' ], resources: [ 'events' ], verbs: [ 'get', 'list', 'watch', 'create', 'update', 'patch' ] },


  ],
};

local controlerClusterRoleBinding = kube.ClusterRoleBinding(controlerName) {
  subjects_: [ controlerServiceAccount ],
  roleRef_: controlerClusterRole,
};

local hcloudToken = kube.Secret('hcloud-token') {
  stringData: {
    token: params.hcloudToken,
  },
};

local controller = kube.Deployment(controlerName) {
  spec+: {
    replicas: 1,
    template+: {
      spec+: {
        serviceAccountName: controlerName,
        containers_:: {
          default: Container('hcloud-csi-driver', 'socket-dir') {
            env_:: {
              CSI_ENDPOINT: 'unix:///run/csi/socket',
              METRICS_ENDPOINT: '0.0.0.0:9189',
              ENABLE_METRICS: 'true',
              KUBE_NODE_NAME: kube.FieldRef('spec.nodeName'),
              HCLOUD_TOKEN: { secretKeyRef: { name: 'hcloud-token', key: 'token' } },
            },
            command: [ '/bin/hcloud-csi-driver-controller' ],
            ports_:: {
              metrics: { containerPort: 9189 },
              healthz: { containerPort: 9808 },
            },
            livenessProbe: {
              failureThreshold: 5,
              httpGet: {
                path: '/healthz',
                port: 'healthz',
              },
              initialDelaySeconds: 10,
              timeoutSeconds: 3,
              periodSeconds: 2,
            },
          },
          attacher: Container('csi-attacher', 'socket-dir') {
            args: [
              '--default-fstype=ext4',
            ],
          },
          provisioner: Container('csi-provisioner', 'socket-dir') {
            args: [
              '--feature-gates=Topology=true',
              '--default-fstype=ext4',
            ],
          },
          resizer: Container('csi-resizer', 'socket-dir'),
          probe: Container('liveness-probe', 'socket-dir'),
        },
        volumes_:: {
          'socket-dir': kube.EmptyDirVolume(),
        },
      },
    },
  },
};

local controllerService = kube.Service(controlerName) {
  target_pod:: controller.spec.template,
  spec+: {
    sessionAffinity: 'None',
  },
};


// CSI Node

local csiNode = kube.DaemonSet('hcloud-csi-node') {
  spec+: {
    template+: {
      spec+: {
        tolerations: [
          { effect: 'NoExecute', operator: 'Exists' },
          { effect: 'NoSchedule', operator: 'Exists' },
          { key: 'CriticalAddonsOnly', operator: 'Exists' },
        ],
        affinity: {
          nodeAffinity: {
            requiredDuringSchedulingIgnoredDuringExecution: {
              nodeSelectorTerms: [ {
                matchExpressions: [ {
                  key: 'instance.hetzner.cloud/is-root-server',
                  operator: 'NotIn',
                  values: [ 'true' ],
                } ],
              } ],
            },
          },
        },
        containers_:: {
          default: Container('hcloud-csi-driver', 'plugin-dir') {
            env_:: {
              CSI_ENDPOINT: 'unix:///run/csi/socket',
              METRICS_ENDPOINT: '0.0.0.0:9189',
              ENABLE_METRICS: 'true',
              KUBE_NODE_NAME: kube.FieldRef('spec.nodeName'),
              HCLOUD_TOKEN: { secretKeyRef: { name: 'hcloud-token', key: 'token' } },
            },
            command: [ '/bin/hcloud-csi-driver-node' ],
            ports_:: {
              metrics: { containerPort: 9189 },
              healthz: { containerPort: 9808 },
            },
            securityContext: { privileged: true },
            livenessProbe: {
              failureThreshold: 5,
              httpGet: {
                path: '/healthz',
                port: 'healthz',
              },
              initialDelaySeconds: 10,
              timeoutSeconds: 3,
              periodSeconds: 2,
            },
            volumeMounts_+: {
              'kubelet-dir': { mountPath: '/var/lib/kubelet', mountPropagation: 'Bidirectional' },
              'device-dir': { mountPath: '/dev' },
            },
          },
          registrar: Container('csi-registrar', 'plugin-dir') {
            args: [
              '--kubelet-registration-path=/var/lib/kubelet/plugins/csi.hetzner.cloud/socket',
            ],
            volumeMounts_+: {
              'registration-dir': { mountPath: '/registration' },
            },
          },
          probe: Container('liveness-probe', 'plugin-dir'),
        },
        volumes_:: {
          'kubelet-dir': { hostPath: { path: '/var/lib/kubelet', type: 'Directory' } },
          'plugin-dir': { hostPath: { path: '/var/lib/kubelet/plugins/csi.hetzner.cloud/', type: 'DirectoryOrCreate' } },
          'registration-dir': { hostPath: { path: '/var/lib/kubelet/plugins_registry/', type: 'Directory' } },
          'device-dir': { hostPath: { path: '/dev', type: 'Directory' } },
        },
      },
    },
  },
};

local csiNodeService = kube.Service('hcloud-csi-node') {
  target_pod:: csiNode.spec.template,
  spec+: {
    sessionAffinity: 'None',
  },
};


// CSI Driver

local csiDriver = kube._Object('storage.k8s.io/v1', 'CSIDriver', 'csi.hetzner.cloud') {
  spec: {
    attachRequired: true,
    podInfoOnMount: true,
    volumeLifecycleModes: [ 'Persistent' ],
    fsGroupPolicy: 'File',
  },
};


// Storage Class

local storageClass = sc.storageClass('hcloud-volumes') {
  allowVolumeExpansion: true,
  provisioner: 'csi.hetzner.cloud',
  volumeBindingMode: 'WaitForFirstConsumer',
};

// Define outputs below
{
  '00_namespace': namespace,
  '10_controller_deploy': controller,
  '10_controller_service': controllerService,
  '10_controller_rbac': [ controlerServiceAccount, controlerClusterRole, controlerClusterRoleBinding ],
  '20_node_deploy': csiNode,
  '20_node_service': csiNodeService,
  '30_csi_driver': csiDriver,
  '40_storage_class': storageClass,
  '50_hcloud_token': hcloudToken,
}
