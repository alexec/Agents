// uses: ConfigChoice, ConfigChoiceGroup, JSONValue
/**
 * ConfigOption (Model/Options.swift), as its encode(to:) writes it: `type` is the kind's
 * wire name, and `options` is a flat list for one unnamed group, else the groups.
 */
export interface ConfigOption {
  id: string;
  name: string;
  description?: string;
  category?: string;
  /** "select", "boolean", or a kind this build doesn't know, carried as itself. */
  type: string;
  currentValue?: JSONValue;
  options?: ConfigChoice[] | ConfigChoiceGroup[];
}
