local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.csi_hetznercloud;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('csi-hetznercloud', params.namespace);

{
  'csi-hetznercloud': app,
}
