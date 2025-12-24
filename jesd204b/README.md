# JESD204B TX controller

## Context

High speed ADC/DACs are required for sending and receiving Microwave pulses to qubits across many QC architectures. I decided to write up a controller RTL for [JESD204B](https://www.ti.com/lit/ml/slap161/slap161.pdf?ts=1765905115257), a high speed interface which commonly sits between high speed data converters and FPGAs.

I am using open source tools: [Verilator](https://github.com/verilator/verilator) for SystemVerilog simulation and [GTKWave](https://gtkwave.sourceforge.net/) for viewing waveforms.

For testing, I wanted to create a UVM-like framework from scratch as an exercise, but Verilator has trouble with virtual interface, required for such a framework as DUT interfaces are driven from within classes via the virtual interface. Therefore, I resorted to flat testbench here.

## Schematics

<img width="691" height="381" alt="image" src="https://github.com/user-attachments/assets/a2a328f1-00bc-419a-a6aa-a413006ac923" />

`tx.sv` implements a controller that sits between (1) the imaginary internal control system logic and (2) the JESD core IP, which controls the transport, link, and PHY layer of JESD204B interface.

Testbench `tb_tx.sv` provides clock and reset, mocks the internal control system logic that drives samples into `tx.sv`, and mocks the JESD core IP. Interface follows AXI handshake protocol.

The state machine of the JESD core IP mock ([reference](https://www.ti.com/lit/ml/slap160/slap160.pdf) for JESD link layer behavior)

<img width="764" height="632" alt="image" src="https://github.com/user-attachments/assets/5e101502-c95f-4a3a-89d9-7bbb3900f6c6" />

## Design

The design of `tx` is pretty simple. It sits between the sample-feeding interface of the internal control system logic on the upstream and the JESD core IP on the downstream, both following AXI handshake. To efficiently transmit data and relay backpressure, the data path features a skid buffer (`skid_buffer.sv`). In this exercise, upstream samples are zero-padded and passed down. `tx` monitors status flags from JESD core IP (`jesd_cgs_done`, `jesd_ilas_done`, `jesd_link_up`) and transmits data when the downstream is expecting data per these flags.

## Implementation notes

I follow particular best practices for synthesizable RTL. For example:

- I like to keep my sequential logic in  `always_ff` blocks free of combinational logic.
- for flops, I like to declare `flop_d` and `flop_q`, update q with d in the sequential blocks, and declare the combinational calculation for `flop_d` (1) with `assign` if it’s simple (2) with `always_comb` cases when it’s not.

I don’t like transitions sharply aligned with clock edges. I like to see propagation delays in my waves. As a result:

- I add `#T_CQ` to model the clock-to-Q delay whenever I do non-blocking assignments.
- I use `clocking` blocks to add skews when I drive signals in the testbench.

## CLI commands

To compile SystemVerilog sources into an executable; the resulting executable `tb_sim` can be found under the generated folder `obj_dir` :

```bash
verilator -Wall --sv --trace --binary tb_tx.sv tx.sv skid_buffer.sv --top-module tb_tx -o tb_sim
```

To run the executable and dump the waveform:

```bash
./obj_dir/tb_sim +VCD
```

To view the waveform:

```bash
GTKWave tb_tx.vcd
```

CLI message indicating test passing:

```bash
>./obj_dir/tb_sim +VCD                                                                           
-----------------------------------------------------------
PASS: Completed simulation. expected_sample_queue is empty.
Matched samples = 501 (dut_ingested_samples=501)
-----------------------------------------------------------
- tb_tx.sv:347: Verilog $finish
- S i m u l a t i o n   R e p o r t: Verilator 5.042 2025-11-02
- Verilator: $finish at 7us; walltime 0.005 s; speed 1.642 ms/s
- Verilator: cpu 0.004 s on 1 threads; alloced 0 MB
```

## Waveform

<img width="2048" height="356" alt="image" src="https://github.com/user-attachments/assets/a4eddef3-568b-4f28-882b-38f6d4e7d58f" />
