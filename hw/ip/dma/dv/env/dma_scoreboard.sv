// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// TODO pending checks
// - handshake interrupt check
// - Alert checks
class dma_scoreboard extends cip_base_scoreboard #(
  .CFG_T(dma_env_cfg),
  .RAL_T(dma_reg_block),
  .COV_T(dma_env_cov)
);
  `uvm_component_utils(dma_scoreboard)

  `uvm_component_new

  // Queue structures holding the expected requests on selected source and destination interfaces
  tl_seq_item src_queue[$];  // Request and response items on source TL interface
  tl_seq_item dst_queue[$];  // Request and response items on destination TL interface

  bit [63:0] last_src_addr; // last observed source address
  bit [63:0] last_dst_addr; // last observed destination address

  // Internal variables to compare transactions
  dma_seq_item dma_config;

  // Indicates if DMA operation is in progress
  bit operation_in_progress;
  // Indicates if current DMA operation is valid or invalid
  bit current_operation_valid = 1;
  // Variable to keep track of number of bytes transferred in current operation
  uint num_bytes_transfered;
  // Variable to indicate if TL error is detected on interface
  bit src_tl_error_detected;
  bit dst_tl_error_detected;
  // Bit to indicate if DMA operation is explicitly aborted with register write
  bit abort_via_reg_write;

  // bit to indicate if dma_memory_buffer_limit interrupt is reached
  bit exp_buffer_limit_intr;
  // Bit to indicate if dma_error interrupt is asserted
  bit exp_dma_err_intr;
  // bit to indicate if dma_done interrupt is asserted
  bit exp_dma_done_intr;
  // bit to indicate dma config clear via register write
  bit clear_via_reg_write;
  // True if in hardware handshake mode and the FIFO interrupt has been cleared
  bit fifo_intr_cleared;
  // Variable to indicate number of writes expected to clear FIFO interrupts
  uint num_fifo_reg_write;
  // Variable to store clear_int_src register intended for use in monitor_lsio_trigger task
  // since ref argument can not be used in fork-join_none
  bit[31:0] clear_int_src;
  bit handshake; // Bit to indicate if handshake mode is enabled

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // Create a_channel analysis fifo
    foreach (cfg.dma_a_fifo[key]) begin
      tl_a_chan_fifos[cfg.dma_a_fifo[key]] = new(cfg.dma_a_fifo[key], this);
    end
    foreach (cfg.dma_d_fifo[key]) begin
      tl_d_chan_fifos[cfg.dma_d_fifo[key]] = new(cfg.dma_d_fifo[key], this);
    end
    foreach (cfg.dma_dir_fifo[key]) begin
      tl_dir_fifos[cfg.dma_dir_fifo[key]] = new(cfg.dma_dir_fifo[key], this);
    end
    dma_config = dma_seq_item::type_id::create("dma_config");
    dma_config.randomize();

  endfunction: build_phase

  // Check if address is valid for different configurations of DMA
  // This method is common for both source and destination address
  function void check_for_valid_addr(bit [63:0] addr,
                                     bit [63:0] last_addr,
                                     bit handshake_mode,
                                     bit fifo_en,
                                     bit [63:0] start_addr,
                                     bit [31:0] total_data_size,
                                     string check_type = "Source");
    `DV_CHECK(addr[1:0] == 0, $sformatf("Address is not 4 Byte aligned"))
    // Handshake mode when the fifo is enabled
    if (handshake_mode && fifo_en) begin
      `DV_CHECK(addr == start_addr,
                $sformatf("0x%0x doesn't match start addr:0x%0x (handshake mode no auto-incr)",
                          addr, start_addr))
    end else begin
      // Addresses generated by DMA are 4-Byte aligned (refer #338)
      bit [63:0] aligned_start_addr = {start_addr[63:2], 2'b00};
      // Generic mode address check
      `DV_CHECK(addr >= aligned_start_addr && addr + 4 <= start_addr + total_data_size,
                $sformatf("0x%0x not in %s addr range", addr, check_type))
    end
  endfunction

  // Process items on Addr channel
  task process_tl_addr_txn(string if_name, ref tl_seq_item item);
    uint expected_txn_size = dma_config.transfer_width_to_a_size(
                               dma_config.per_transfer_width);
    uint expected_per_txn_bytes = dma_config.transfer_width_to_num_bytes(
                                    dma_config.per_transfer_width);
    tl_a_op_e a_opcode = tl_a_op_e'(item.a_opcode);
    `uvm_info(`gfn, $sformatf("Got addr txn \n:%s", item.sprint()), UVM_DEBUG)
    // Common checks
    // Check if the transaction is of correct size
    `DV_CHECK_EQ(item.a_size, 2); // Always 4B
    // Interface specific checks
    // - Read transactions are from Source interface and
    // - Write transactions are to destination interface
    if (!item.is_write()) begin // read transaction
      // Check if the transaction has correct mask
      `DV_CHECK_EQ($countones(item.a_mask), 4) // Always 4B
      // Check source ASID for read transaction
      `DV_CHECK_EQ(if_name,
                   cfg.asid_interace_map[dma_config.src_asid],
                   $sformatf("Unexpected read txn on %s interface with source ASID %s",
                             if_name, dma_config.src_asid.name()))
      // Check if opcode is as expected
      `DV_CHECK(a_opcode inside {Get},
               $sformatf("Unexpected opcode : %d on %s", a_opcode.name(), if_name))
      // Check if the transaction address is in source address range
      check_for_valid_addr(item.a_addr,
                           last_src_addr,
                           dma_config.handshake,
                           dma_config.get_read_fifo_en(),
                           dma_config.src_addr,
                           dma_config.total_transfer_size,
                           "Source");
      // Update the expected value of memory buffer limit interrupt for source address
      if (dma_config.src_asid == OtInternalAddr && item.a_addr > dma_config.mem_buffer_limit) begin
        exp_buffer_limit_intr = 1;
        `uvm_info(`gfn, $sformatf("Source item addr:%0x crosses mem buffer limit: %0x",
                                  item.a_addr, dma_config.mem_buffer_limit), UVM_HIGH)
      end
      // Push addr item to source queue
      src_queue.push_back(item);
      `uvm_info(`gfn, $sformatf("Addr channel checks done for source item"), UVM_HIGH)
      // Update last address
      last_src_addr = item.a_addr;
    end else begin // Write transaction
      uint remaining_bytes = dma_config.total_transfer_size - num_bytes_transfered;
      uint exp_a_mask_count_ones = remaining_bytes > dma_config.per_transfer_width ?
                                   expected_per_txn_bytes : remaining_bytes;
      uint num_bytes_this_txn = $countones(item.a_mask);
      // check if a_mask matches the data size
      `DV_CHECK_EQ(num_bytes_this_txn, exp_a_mask_count_ones,
                   $sformatf("unexpected a_mask: %x for %0d byte transfer",
                           item.a_mask, expected_per_txn_bytes))
      // Enable write address check if handshake mode is disabled or
      // if the FIFO interrupt has been cleared even though handshake mode is enabled
      if (!dma_config.handshake || fifo_intr_cleared) begin
        // Check destination ASID for write transaction
        `DV_CHECK_EQ(if_name,
                     cfg.asid_interace_map[dma_config.dst_asid],
                     $sformatf("Unexpected write txn on %s interface with destination ASID %s",
                               if_name, dma_config.dst_asid.name()))
        // Check if the transaction address is in destination address range
        check_for_valid_addr(item.a_addr,
                             last_dst_addr,
                             dma_config.handshake,
                             dma_config.get_write_fifo_en(),
                             dma_config.dst_addr,
                             dma_config.total_transfer_size,
                             "Destination");
      end
      // Check if opcode is as expected
      if ((dma_config.per_transfer_width != DmaXfer4BperTxn) ||
          (remaining_bytes < dma_config.per_transfer_width)) begin
        `DV_CHECK(a_opcode inside {PutPartialData},
                  $sformatf("Unexpected opcode : %d on %s", a_opcode.name(), if_name))
      end else begin
        `DV_CHECK(a_opcode inside {PutFullData},
                  $sformatf("Unexpected opcode : %d on %s", a_opcode.name(), if_name))
      end
      // Update the expected value of memory buffer limit interrupt for source address
      if (dma_config.src_asid == OtInternalAddr && item.a_addr > dma_config.mem_buffer_limit) begin
        exp_buffer_limit_intr = 1;
        `uvm_info(`gfn, $sformatf("Source item addr:%0x crosses mem buffer limit: %0x",
                                  item.a_addr, dma_config.mem_buffer_limit), UVM_LOW)
      end
      // Push addr item to destination queue
      dst_queue.push_back(item);
      `uvm_info(`gfn, $sformatf("Addr channel checks done for destination item"), UVM_HIGH)
      // Update last address
      last_dst_addr = item.a_addr;
      // Update number of bytes transferred only in case of write txn - refer #338
      num_bytes_transfered += num_bytes_this_txn;
    end
    // Update expected value of dma_done interrupt
    exp_dma_done_intr = (num_bytes_transfered >= dma_config.total_transfer_size);
  endtask

  // Process items on Data channel
  task process_tl_data_txn(string if_name, ref tl_seq_item item);
    bit got_source_item = 0;
    bit got_dest_item = 0;
    uint queue_idx = 0;
    tl_d_op_e d_opcode = tl_d_op_e'(item.d_opcode);
    // Check if there is a previous address request with the
    // same source id as the current data request
    foreach (src_queue[i]) begin
      if (item.d_source == src_queue[i].a_source) begin
        got_source_item = 1;
        queue_idx = i;
        `uvm_info(`gfn, $sformatf("Found data item with source id %0d at index: %0d",
                                  item.d_source, queue_idx), UVM_HIGH)
      end
    end
    // Check if there is a previous address request with the
    // same destination id as the current data request
    if (!got_source_item) begin
      foreach (dst_queue[i]) begin
        if (item.d_source == dst_queue[i].a_source) begin
          got_dest_item = 1;
          queue_idx = i;
          `uvm_info(`gfn, $sformatf("Found data item with destination id %0d at index: %0d",
                                    item.d_source, queue_idx), UVM_HIGH)
        end
      end
    end

    // Check if Data item has an outstanding address item
    `DV_CHECK(got_source_item || got_dest_item,
              $sformatf("Data item source id doesnt match any outstanding request"))
    // Source interface item checks
    if (got_source_item) begin
      src_tl_error_detected = item.d_error;
      if (src_tl_error_detected) begin
        `uvm_info(`gfn, "Detected TL error on Source Data item", UVM_HIGH)
      end
      // Check if data item opcode is as expected
      `DV_CHECK(d_opcode inside {AccessAckData},
                $sformatf("Invalid opcode %s for source data item", d_opcode))
      // Delete after all checks related to data channel are done
      `uvm_info(`gfn, $sformatf("Deleting element at %d index in source queue", queue_idx),
                UVM_HIGH)
      src_queue.delete(queue_idx);
    end else if (got_dest_item) begin
      // Destination interface item checks
      dst_tl_error_detected = item.d_error;
      if (dst_tl_error_detected) begin
        `uvm_info(`gfn, "Detected TL error on Destination Data item", UVM_HIGH)
      end
      // Check if data item opcode is as expected
      `DV_CHECK(d_opcode inside {AccessAck},
                $sformatf("Invalid opcode %s for destination data item", d_opcode))
      // Delete after all checks related to data channel are done
      `uvm_info(`gfn, $sformatf("Deleting element at %d index in destination queue", queue_idx),
                UVM_HIGH)
      dst_queue.delete(queue_idx);
    end
  endtask

  // Method to process requests on TL interfaces
  task process_tl_txn(string if_name,
                      uvm_tlm_analysis_fifo#(tl_channels_e) dir_fifo,
                      uvm_tlm_analysis_fifo#(tl_seq_item) a_chan_fifo,
                      uvm_tlm_analysis_fifo#(tl_seq_item) d_chan_fifo);
    tl_channels_e dir;
    tl_seq_item   item;
    fork
      forever begin
        dir_fifo.get(dir);
        // Check if transaction is expected for a valid configuration
        `DV_CHECK_EQ_FATAL(dma_config.is_valid_config, 1,
                           $sformatf("transaction observed on %s for invalid configuration",
                                     if_name))
        // Check if there is any active operation
        `DV_CHECK_FATAL(operation_in_progress, "transaction detected with no active operation")
        case (dir)
          AddrChannel: begin
            `DV_CHECK_FATAL(a_chan_fifo.try_get(item),
                            "dir_fifo pointed at A channel, but a_chan_fifo empty")
            `uvm_info(`gfn, $sformatf("received %s a_chan %s item with addr: %0x and data: %0x",
                                      if_name,
                                      item.is_write() ? "write" : "read",
                                      item.a_addr,
                                      item.a_data), UVM_HIGH)
            process_tl_addr_txn(if_name, item);
            // Update num_fifo_reg_write
            if (num_fifo_reg_write > 0) begin
              `uvm_info(`gfn, $sformatf("Processed FIFO clear_int_src addr: %0x0x", item.a_addr),
                        UVM_DEBUG)
              num_fifo_reg_write--;
            end else begin
              // Set status bit after all FIFO interrupt clear register writes are done
              fifo_intr_cleared = 1;
            end
          end
          DataChannel: begin
            `DV_CHECK_FATAL(d_chan_fifo.try_get(item),
                            "dir_fifo pointed at D channel, but d_chan_fifo empty")
            `uvm_info(`gfn, $sformatf("received %s d_chan item with addr: %0x and data: %0x",
                                      if_name, item.a_addr, item.d_data), UVM_HIGH)
            // TODO add method to process Data transactions
          end
          default: `uvm_fatal(`gfn, "Invalid entry in dir_fifo")
        endcase
      end
    join_none
  endtask

  // Clear internal variables on reset
  virtual function void reset(string kind = "HARD");
    super.reset();
    `uvm_info(`gfn, "Detected DMA reset", UVM_LOW)
    current_operation_valid = 1'b0;
    dma_config.reset_config();
    src_queue.delete();
    dst_queue.delete();
    operation_in_progress = 1'b0;
    num_bytes_transfered = 0;
    src_tl_error_detected = 0;
    dst_tl_error_detected = 0;
    abort_via_reg_write = 0;
    exp_buffer_limit_intr = 0;
    exp_dma_done_intr = 0;
    exp_dma_err_intr = 0;
    fifo_intr_cleared = 0;
  endfunction

  // Method to check if DMA interrupt is expected
  task monitor_and_check_dma_interrupts(ref dma_seq_item dma_config);
    fork
      // DMA memory buffer limit interrupt check
      forever begin
        @(posedge cfg.intr_vif.pins[DMA_MEMORY_BUFFER_LIMIT_INTR]);
        if (!cfg.under_reset) begin
          `DV_CHECK_EQ(exp_buffer_limit_intr, 1,
                       "Unexpected assertion of dma_memory_buffer_limit interrupt")
        end
      end
      // DMA Error interrupt check
      forever begin
        @(posedge cfg.intr_vif.pins[DMA_ERROR]);
        if (!cfg.under_reset) begin
          `DV_CHECK_EQ(exp_dma_err_intr, 1, "Unexpected assertion of dma_error interrupt")
        end
      end
      // DMA done interrupt check
      forever begin
        @(posedge cfg.intr_vif.pins[DMA_DONE]);
        if (!cfg.under_reset) begin
          `DV_CHECK_EQ(exp_dma_done_intr, 1, "Unexpected assertion of DMA_DONE interrupt")
        end
      end
    join_none
  endtask

  // Task to monitor LSIO trigger and update scoreboard internal variables
  task monitor_lsio_trigger();
    fork
      begin
        forever begin
          uvm_reg_data_t handshake_en;
          uvm_reg_data_t handshake_intr_en;
          // Wait for at least one LSIoO trigger to be active and it is eanbled
          @(posedge cfg.dma_vif.handshake_i);
          handshake_en = `gmv(ral.control.hardware_handshake_enable);
          handshake_intr_en = `gmv(ral.handshake_interrupt_enable);
          // Update number of register writes expected in case at least one
          // of the enabled handshake interrupt is asserted
          if (handshake_en && (cfg.dma_vif.handshake_i & handshake_intr_en)) begin
            num_fifo_reg_write = $countones(clear_int_src);
            `uvm_info(`gfn,
                      $sformatf("Handshake mode: num_fifo_reg_write:%0d", num_fifo_reg_write),
                      UVM_HIGH)
          end
        end
      end
    join_none
  endtask

  function void check_phase(uvm_phase phase);
    // Check if there are unprocessed source items
    uint size = src_queue.size();
    `DV_CHECK_EQ(size, 0, $sformatf("%0d unhandled source interface transactions",size))
    // Check if there are unprocessed destination items
    size = dst_queue.size();
    `DV_CHECK_EQ(size, 0, $sformatf("%0d unhandled destination interface transactions",size))
    // Check if DMA operation is in progress
    `DV_CHECK_EQ(operation_in_progress, 0, "DMA operation imcomplete")
  endfunction

  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    num_fifo_reg_write = 0;
    // Call process methods on TL fifo
    foreach (cfg.fifo_names[i]) begin
      process_tl_txn(cfg.fifo_names[i],
                     tl_dir_fifos[cfg.dma_dir_fifo[cfg.fifo_names[i]]],
                     tl_a_chan_fifos[cfg.dma_a_fifo[cfg.fifo_names[i]]],
                     tl_d_chan_fifos[cfg.dma_d_fifo[cfg.fifo_names[i]]]);
    end
    monitor_and_check_dma_interrupts(dma_config);
    monitor_lsio_trigger();
  endtask

  // Function to get the memory model data at provided address
  function bit[7:0] get_model_data(asid_encoding_e asid, bit [63:0] addr);
    case (asid)
      OtInternalAddr : return cfg.mem_host.read_byte(addr);
      SocControlAddr,
      OtExtFlashAddr : return cfg.mem_ctn.read_byte(addr);
      SocSystemAddr : return cfg.mem_sys.read_byte(addr);
      default: begin
        `uvm_error(`gfn, $sformatf("Unsupported Address space ID %d", asid))
      end
    endcase
  endfunction

  // Wrapper function to check the data and addresses in each memory model
  function void check_data(ref dma_seq_item dma_config);
    bit [63:0] src_addr = dma_config.src_addr;
    bit [63:0] dst_addr = dma_config.dst_addr;
    for (int i = 0; i < dma_config.total_transfer_size; i++) begin
      `uvm_info(`gfn,
                $sformatf("checking src_addr = %0x dst_addr = %0x", src_addr, dst_addr),
                UVM_DEBUG)
      `DV_CHECK_EQ(get_model_data(dma_config.src_asid, src_addr),
                   get_model_data(dma_config.dst_asid, dst_addr),
                   $sformatf("src_addr = %0x dst_addr = %0x", src_addr, dst_addr))
      src_addr++;
      dst_addr++;
    end
  endfunction

  // Return the index that a register name refers to e.g. "int_source_addr_1" yields 1
  function uint get_index_from_reg_name(string reg_name);
    int str_len = reg_name.len();
    string index_str = reg_name.substr(str_len-2, str_len-1);
    return index_str.atoi();
  endfunction

  // Method to process DMA register write
  function void process_reg_write(tl_seq_item item, uvm_reg csr);
    `uvm_info(`gfn, $sformatf("Got reg_write to %s with addr : %0x and data : %0x ",
                              csr.get_name(), item.a_addr, item.a_data), UVM_HIGH)
    // incoming access is a write to a valid csr, so make updates right away
    void'(csr.predict(.value(item.a_data), .kind(UVM_PREDICT_WRITE), .be(item.a_mask)));

    case (csr.get_name())
      "source_address_lo": begin
        dma_config.src_addr[31:0] = item.a_data;
        `uvm_info(`gfn, $sformatf("Got source_address_lo = %0x",
                                  dma_config.src_addr[31:0]), UVM_HIGH)
      end
      "source_address_hi": begin
        dma_config.src_addr[63:32] = item.a_data;
        `uvm_info(`gfn, $sformatf("Got source_address_hi = %0x",
                                  dma_config.src_addr[63:32]), UVM_HIGH)
      end
      "destination_address_lo": begin
        dma_config.dst_addr[31:0] = item.a_data;
        `uvm_info(`gfn, $sformatf("Got destination_address_lo = %0x",
                                  dma_config.dst_addr[31:0]), UVM_HIGH)
      end
      "destination_address_hi": begin
        dma_config.dst_addr[63:32] = item.a_data;
        `uvm_info(`gfn, $sformatf("Got destination_address_hi = %0x",
                                  dma_config.dst_addr[63:32]), UVM_HIGH)
      end
      "address_space_id": begin
        // Get mirrored field value and cast to associated enum in dma_config
        dma_config.src_asid = asid_encoding_e'(`gmv(ral.address_space_id.source_asid));
        `uvm_info(`gfn, $sformatf("Got source address space id : %s",
                                  dma_config.src_asid.name()), UVM_HIGH)
        // Get mirrored field value and cast to associated enum in dma_config
        dma_config.dst_asid = asid_encoding_e'(`gmv(ral.address_space_id.destination_asid));
        `uvm_info(`gfn, $sformatf("Got destination address space id : %s",
                                  dma_config.dst_asid.name()), UVM_HIGH)
      end
      "enabled_memory_range_base": begin
        if (dma_config.mem_range_unlock == MuBi4True) begin
          dma_config.mem_range_base = item.a_data;
          `uvm_info(`gfn, $sformatf("Got enabled_memory_range_base = %0x",
                                    dma_config.mem_range_base), UVM_HIGH)
        end
      end
      "enabled_memory_range_limit": begin
        if (dma_config.mem_range_unlock == MuBi4True) begin
          dma_config.mem_range_limit = item.a_data;
          `uvm_info(`gfn, $sformatf("Got enabled_memory_range_limit = %0x",
                                    dma_config.mem_range_limit), UVM_HIGH)
        end
      end
      "range_unlock_regwen": begin
        // Get mirrored field value and cast to associated enum in dma_config
        dma_config.mem_range_unlock = mubi4_t'(`gmv(ral.range_unlock_regwen.unlock));
        `uvm_info(`gfn, $sformatf("Got range register unlock = %s",
                                  dma_config.mem_range_unlock.name()), UVM_HIGH)
      end
      "total_data_size": begin
        dma_config.total_transfer_size = item.a_data;
        `uvm_info(`gfn, $sformatf("Got total_data_size = %0d B",
                                  dma_config.total_transfer_size), UVM_HIGH)
      end
      "transfer_width": begin
        dma_config.per_transfer_width = dma_transfer_width_e'(
                                            `gmv(ral.transfer_width.transaction_width));
        `uvm_info(`gfn, $sformatf("Got transfer_width = %s",
                                  dma_config.per_transfer_width.name()), UVM_HIGH)
      end
      "destination_address_limit_lo": begin
        dma_config.mem_buffer_limit[31:0] =
          `gmv(ral.destination_address_limit_lo.address_limit_lo);
      end
      "destination_address_limit_hi": begin
        dma_config.mem_buffer_limit[63:32] =
          `gmv(ral.destination_address_limit_hi.address_limit_hi);
      end
      "destination_address_almost_limit_lo": begin
        dma_config.mem_buffer_almost_limit[31:0] =
          `gmv(ral.destination_address_almost_limit_lo.address_limit_lo);
      end
      "destination_address_almost_limit_hi": begin
        dma_config.mem_buffer_almost_limit[63:32] =
          `gmv(ral.destination_address_almost_limit_hi.address_limit_hi);
      end
      "clear_int_bus": begin
        dma_config.clear_int_bus = `gmv(ral.clear_int_bus.bus);
      end
      "clear_int_src": begin
        dma_config.clear_int_src = `gmv(ral.clear_int_src.source);
        clear_int_src = dma_config.clear_int_src;
      end
      "int_source_addr_0",
      "int_source_addr_1",
      "int_source_addr_2",
      "int_source_addr_3",
      "int_source_addr_4",
      "int_source_addr_5",
      "int_source_addr_6",
      "int_source_addr_7": begin
        int index;
        `uvm_info(`gfn, $sformatf("Update %s", csr.get_name()), UVM_DEBUG)
        index = get_index_from_reg_name(csr.get_name());
        dma_config.int_src_addr[index] = item.a_data;
      end
      "int_source_wr_val_0",
      "int_source_wr_val_1",
      "int_source_wr_val_2",
      "int_source_wr_val_3",
      "int_source_wr_val_4",
      "int_source_wr_val_5",
      "int_source_wr_val_6",
      "int_source_wr_val_7": begin
        int index;
        `uvm_info(`gfn, $sformatf("Update %s", csr.get_name()), UVM_DEBUG)
        index = get_index_from_reg_name(csr.get_name());
        dma_config.int_src_wr_val[index] = item.a_data;
      end
      "control": begin
        // bit to indicate start of DMA operation
        bit go = `gmv(ral.control.go);
        `uvm_info(`gfn, $sformatf("Got GO = %0b", go), UVM_HIGH)
        // Get mirrored field value and cast to associated enum in dma_config
        dma_config.opcode = opcode_e'(`gmv(ral.control.opcode));
        `uvm_info(`gfn, $sformatf("Got opcode = %s", dma_config.opcode.name()), UVM_HIGH)
        // Get handshake mode enable bit
        dma_config.handshake = `gmv(ral.control.hardware_handshake_enable);
        handshake = dma_config.handshake;
        `uvm_info(`gfn, $sformatf("Got hardware_handshake_mode = %0b", dma_config.handshake),
                  UVM_HIGH)
        // Update the value of abort as this stops the DMA operation
        abort_via_reg_write = `gmv(ral.control.abort);
        if (abort_via_reg_write) begin
          `uvm_info(`gfn, "Detected Abort operation", UVM_LOW)
        end
        // Get auto-increment bit
        dma_config.auto_inc_buffer = `gmv(ral.control.memory_buffer_auto_increment_enable);
        dma_config.auto_inc_fifo = `gmv(ral.control.fifo_auto_increment_enable);
        if (go) begin
          `uvm_info(`gfn, $sformatf("dma_config\n %s",
                                    dma_config.sprint()), UVM_HIGH)
          // Check if configuration is valid
          operation_in_progress = 1'b1;
          last_src_addr = dma_config.src_addr - 1;
          last_dst_addr = dma_config.dst_addr - 1;
          dma_config.is_valid_config = dma_config.check_config();
          `uvm_info(`gfn, $sformatf("dma_config.is_valid_config = %b",
                                    dma_config.is_valid_config), UVM_MEDIUM)
          exp_dma_err_intr = !dma_config.is_valid_config;
          if (cfg.en_cov) begin
            // Sample dma configuration
            cov.config_cg.sample(.dma_config (dma_config),
                                 .abort (abort_via_reg_write),
                                 .write_to_dma_mem_register(1'b0),
                                 .tl_src_err (1'b0),
                                 .tl_dst_err (1'b0));
          end
          fifo_intr_cleared = 0;
        end
      end
      "clear_state": begin
        uvm_reg_data_t status = `gmv(ral.status.busy);
        clear_via_reg_write = get_field_val(ral.clear_state.clear, item.d_data);
        if (cfg.en_cov) begin
          // Sample dma configuration status
          cov.status_cg.sample(.busy (get_field_val(ral.status.busy, status)),
                               .done (get_field_val(ral.status.done, status)),
                               .aborted (get_field_val(ral.status.aborted, status)),
                               .error (get_field_val(ral.status.error, status)),
                               .error_code (get_field_val(ral.status.error_code, status)),
                               .clear (clear_via_reg_write));
        end
      end
      default: begin
        `uvm_info(`gfn, $sformatf("%s not processed", csr.get_name()), UVM_MEDIUM)
      end
    endcase
  endfunction

  // Method to process DMA register read
  function void process_reg_read(tl_seq_item item, uvm_reg csr);
    // After reads, if do_read_check is set, compare the mirrored_value against item.d_data
    bit do_read_check = 1'b1;
    `uvm_info(`gfn, $sformatf("Got reg_read to %s with addr : %0x and data : %0x ",
                              csr.get_name(), item.a_addr, item.a_data), UVM_HIGH)
    case (csr.get_name())
      "intr_state": begin
        `uvm_info(`gfn, $sformatf("intr_state = %0x", item.d_data), UVM_MEDIUM)
        do_read_check = 1;
      end
      "status": begin
        bit busy, done, aborted, error;
        bit [6:0] error_code;
        bit exp_aborted = src_tl_error_detected || abort_via_reg_write;
        do_read_check = 1'b0;
        busy = get_field_val(ral.status.busy, item.d_data);
        done = get_field_val(ral.status.done, item.d_data);
        aborted = get_field_val(ral.status.aborted, item.d_data);
        error = get_field_val(ral.status.error, item.d_data);
        error_code = get_field_val(ral.status.error_code, item.d_data);
        if (done || aborted || error) begin
          operation_in_progress = 1'b0;
          `uvm_info(`gfn, "Detected end of DMA operation", UVM_MEDIUM)
          // Clear variables
          num_fifo_reg_write = 0;
        end
        // Check total data transferred at the end of DMA operation
        if (done && // dont bit detected in STATUS
            !(aborted || error) && // no abort or error detected
           !(src_tl_error_detected || dst_tl_error_detected))
        begin // no TL error
            // Check if number of bytes transferred is as expected
            `DV_CHECK_EQ(dma_config.total_transfer_size, num_bytes_transfered,
                         $sformatf("exp_data_size: %0d obs_data_size: %0d",
                                   dma_config.total_transfer_size, num_bytes_transfered))
        end
        // Check if aborted bit is set if there is a TL error
        `DV_CHECK_EQ(aborted, exp_aborted, "Aborted bit not set with TL error or DMA config err")
        if (cfg.en_cov) begin
          // Sample dma configuration status
          cov.status_cg.sample(.busy (busy),
                               .done (done),
                               .aborted (aborted),
                               .error (error),
                               .error_code (error_code),
                               .clear (clear_via_reg_write));
        end
        // Check data and addresses in source and destination mem models
        if (done) begin
          check_data(dma_config);
        end
      end
      // Register read check for unlock register
      "range_unlock_regwen": begin
        do_read_check = 1'b0;
      end
      default: do_read_check = 1'b0;
    endcase

    if (do_read_check) begin
      `DV_CHECK_EQ(csr.get_mirrored_value(), item.d_data, $sformatf("reg name: %0s",
                                                                    csr.get_full_name()))
      void'(csr.predict(.value(item.d_data), .kind(UVM_PREDICT_READ)));
    end
  endfunction

  // Main method to process transactions on register configuration interface
  virtual task process_tl_access(tl_seq_item item, tl_channels_e channel, string ral_name);
    uvm_reg csr;

    bit write = item.is_write();

    uvm_reg_addr_t csr_addr = cfg.ral_models[ral_name].get_word_aligned_addr(item.a_addr);
    // if access was to a valid csr, get the csr handle
    if (csr_addr inside {cfg.ral_models[ral_name].csr_addrs}) begin
      csr = cfg.ral_models[ral_name].default_map.get_reg_by_offset(csr_addr);
      `DV_CHECK_NE_FATAL(csr, null)
    end else begin
      `uvm_fatal(`gfn, $sformatf("\naccess unexpected addr 0x%0h", csr_addr))
    end

    // The access is to a valid CSR, now process it.
    // writes -> update local variable and fifo at A-channel access
    // reads  -> update predication at address phase and compare at D-channel access
    if (write && channel == AddrChannel) begin
      process_reg_write(item, csr);
    end  // addr_phase_write

    if (!write && channel == DataChannel) begin
      process_reg_read(item,csr);
    end  // data_phase_read
  endtask : process_tl_access

endclass
