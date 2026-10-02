// uses: Lease, LineMember, DeclaredResource, ResourceKind, ResourceName
/**
 * ResourceState (Daemon/DaemonAPI.swift), as its encode(to:) writes it (#116): every holder in
 * `holds`, and the first again as `lease` for a reader from before counted holders. A host from
 * before #116 sends only `lease`, so `holds`, `places` and `declared` may be missing.
 */
export interface ResourceState {
  name: ResourceName;
  kind: ResourceKind;
  displayName: string;
  isGone: boolean;
  holds?: Lease[];
  lease?: Lease;
  places?: number;
  declared?: DeclaredResource;
  line: LineMember[];
  endingSoon: boolean;
}
