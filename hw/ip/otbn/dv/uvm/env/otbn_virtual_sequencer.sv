// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

class otbn_virtual_sequencer extends cip_base_virtual_sequencer #(
    .CFG_T(otbn_env_cfg),
    .COV_T(otbn_env_cov)
  );
  `uvm_component_utils(otbn_virtual_sequencer)
  `uvm_component_new

  key_sideload_sequencer#(keymgr_pkg::otbn_key_req_t) key_sideload_sequencer_h;

endclass
