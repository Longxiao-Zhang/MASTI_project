/*
* Copyright 2018-present Ralf Kundel, Nikolas Eller
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*    http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

#include <core.p4>
#include <v1model.p4>

//#define ENABLE_DEBUG_TABLES
//#define CODEL_IMPLEMENTED
#define MONITOR_ENABLED

#include "header.p4"
#include "codel.p4"
#include "tcp_checksum.p4"

#define PKT_INSTANCE_TYPE_INGRESS_CLONE 1
#define NUM_PORT 2
#define REGISTER_ID 1
#define MONITORING_INTERVAL 100000      // 100 ms monitoring interval
#define MAX_PACKET_LATENCY_1 60000         // 30 ms of application packet delay limit
#define MAX_PACKET_LATENCY_2 80000         // 20 ms of application packet delay limit
#define MAX_PACKET_DROPS 0              // Maximum number of consecutive packet drops rejected

register<bit<48>>(NUM_PORT) r_recent_latency;
register<bit<48>>(NUM_PORT) r_last_monitor_time;
register<bit<16>>(NUM_PORT) r_packets_dropped;
register<bit<1>>(NUM_PORT) r_dropping_state;
//const bit<32> BMV2_V1MODEL_INSTANCE_TYPE_INGRESS_CLONE = 1;

//#define IS_I2E_CLONE(std_meta) (std_meta.instance_type == BMV2_V1MODEL_INSTANCE_TYPE_INGRESS_CLONE)

//const bit<32> I2E_CLONE_SESSION_ID = 5;

parser ParserImpl(packet_in packet, out headers hdr, inout metadata meta, inout standard_metadata_t standard_metadata) {
    
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        meta.routing_metadata.tcpLength = hdr.ipv4.totalLen;
        transition select(hdr.ipv4.protocol) {
            8w17: parse_udp;
            8w6: parse_tcp;
            default: accept;
        }
    }

    state parse_payload {
        packet.extract(hdr.tcp_options);
        packet.extract(hdr.monitor);
        transition accept;
    }

    state parse_tcp {
        packet.extract(hdr.tcp);
        transition select(hdr.tcp.dataOffset) {
            #ifdef MONITOR_ENABLED
                4w0x8: parse_payload;
            #endif

            default: accept;
        }
    }

    state parse_udp {
        packet.extract(hdr.udp);
        transition select(hdr.udp.destPort) {
            default: accept;
        }
    }

    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.ethertype) {
            16w0x800: parse_ipv4;
            default: accept;
        }
    }
}

#ifdef ENABLE_DEBUG_TABLES
control debug_std_meta(in standard_metadata_t standard_metadata)
{
    table dbg_table {
        key = {
            // This is a complete list of fields inside of the struct
            // standard_metadata_t as of the 2018-Sep-01 version of
            // p4c in the file p4c/p4include/v1model.p4.

            // parser_error is commented out because the p4c back end
            // for bmv2 as of that date gives an error if you include
            // a field of type 'error' in a table key.
            standard_metadata.ingress_port : exact;
            standard_metadata.egress_spec : exact;
            standard_metadata.egress_port : exact;
            standard_metadata.instance_type : exact;
            standard_metadata.packet_length : exact;
            standard_metadata.enq_timestamp : exact;
            standard_metadata.enq_qdepth : exact;
            standard_metadata.deq_timedelta : exact;
            standard_metadata.deq_qdepth : exact;
            standard_metadata.ingress_global_timestamp : exact;
            standard_metadata.egress_global_timestamp : exact;
            standard_metadata.mcast_grp : exact;
            standard_metadata.egress_rid : exact;
            standard_metadata.checksum_error : exact;
            //standard_metadata.parser_error : exact;
        }
        actions = { NoAction; }
        const default_action = NoAction();
    }
    apply {
        dbg_table.apply();
    }
}

control my_debug_1(in headers hdr, in metadata meta)
{
    table dbg_table {
        key = {
            hdr.ipv4.dstAddr : exact;
            hdr.monitor.if_monitor: exact;
            hdr.monitor.received: exact;
            hdr.monitor.send_time: exact;
            hdr.monitor.relative_time: exact;
            hdr.monitor.time_left: exact;
            //meta.fwd.fptr : exact;
        }
        actions = { NoAction; }
        const default_action = NoAction();
    }
    apply {
        dbg_table.apply();
    }
}
#endif  // ENABLE_DEBUG_TABLES

control egress(inout headers hdr, inout metadata meta, inout standard_metadata_t standard_metadata) {
    
    #ifdef ENABLE_DEBUG_TABLES
        debug_std_meta() debug_std_meta_egress_start;
        debug_std_meta() debug_std_meta_egress_end;
        my_debug_1() my_debug_2_1;
        my_debug_1() my_debug_2_2;
    #endif  // ENABLE_DEBUG_TABLES

    #ifdef CODEL_IMPLEMENTED
        c_codel() c_codel_0;
    #endif 

    c_checksum() c_checksum_0;
    //c_add_queue_delay() c_add_queue_delay_0;

    /*
    action change_addrs() {
        bit<48> temp = hdr.ethernet.src_addr;
        hdr.ethernet.src_addr = hdr.ethernet.dst_addr;
        hdr.ethernet.dst_addr = temp;
        hdr.ipv4.dstAddr = hdr.ipv4.srcAddr;
    }

    table exchange_address {
        actions = {
            change_addrs;
        }
        key = {
            hdr.ipv4.srcAddr : exact; 
        }
    }
    */

    action drop_packet() {
        mark_to_drop(standard_metadata);
    }

    apply {
    
        #ifdef ENABLE_DEBUG_TABLES
            debug_std_meta_egress_start.apply(standard_metadata);
            my_debug_2_1.apply(hdr, meta);
        #endif  // ENABLE_DEBUG_TABLES 
        


        if (hdr.monitor.isValid() && hdr.ipv4.totalLen > 500) {
            if (meta.fwd.to_monitor != 0) {
                // Packet to be sent to monitor

                hdr.monitor.send_time = standard_metadata.egress_global_timestamp;
            }

            if (standard_metadata.instance_type == PKT_INSTANCE_TYPE_INGRESS_CLONE) {
                // Packet is a clone to reply back with monitor data
                hdr.ipv4.dstAddr = hdr.ipv4.srcAddr;
                hdr.monitor.received = 4w1;
                hdr.monitor.relative_time = (standard_metadata.egress_global_timestamp - standard_metadata.ingress_global_timestamp);
                //exchange_address.apply();
            }
            else {
                r_recent_latency.read(meta.l_latency.recent_latency, REGISTER_ID);
                bit<48> time_to_reach = standard_metadata.egress_global_timestamp - standard_metadata.ingress_global_timestamp + meta.l_latency.recent_latency;
                
                if (time_to_reach >= hdr.monitor.time_left) {
                    r_dropping_state.read(meta.l_latency.drop_state, REGISTER_ID);
                    r_packets_dropped.read(meta.l_latency.pkt_drops, REGISTER_ID);
                    
                    if (meta.l_latency.drop_state == 1) {
                        
                        if (meta.l_latency.pkt_drops > MAX_PACKET_DROPS) {
                            r_packets_dropped.write(REGISTER_ID, 16w0);
                            drop_packet();
                        }
                        else {
                            meta.l_latency.pkt_drops = meta.l_latency.pkt_drops + 1;
                            r_packets_dropped.write(REGISTER_ID, meta.l_latency.pkt_drops);
                        }    
                    }
                    
                    else {
                        r_dropping_state.write(REGISTER_ID, 1);
                        r_packets_dropped.write(REGISTER_ID, 1);
                    }
                }
                
                else {
                    hdr.monitor.time_left = hdr.monitor.time_left - time_to_reach;
                    r_dropping_state.write(REGISTER_ID, 0);
                }
            }
        }

        #ifdef CODEL_IMPLEMENTED
            if (standard_metadata.ingress_port == 9w1) {
	            meta.codel.queue_id = standard_metadata.egress_port;
                c_codel_0.apply(hdr, meta, standard_metadata);
            }
        #endif
        c_checksum_0.apply(hdr, meta);



        #ifdef ENABLE_DEBUG_TABLES
            debug_std_meta_egress_end.apply(standard_metadata);
            my_debug_2_2.apply(hdr, meta);
        #endif  // ENABLE_DEBUG_TABLES

    }
}

control ingress(inout headers hdr, inout metadata meta, inout standard_metadata_t standard_metadata) {
    
    #ifdef ENABLE_DEBUG_TABLES
        debug_std_meta() debug_std_meta_ingress_start;
        debug_std_meta() debug_std_meta_ingress_end;
        my_debug_1() my_debug_1_1;
        my_debug_1() my_debug_1_2;
    #endif  // ENABLE_DEBUG_TABLES

    action forward(bit<9> egress_spec, bit<48> dst_mac) {
        standard_metadata.egress_spec = egress_spec;
        hdr.ethernet.dst_addr = dst_mac;

        if (hdr.monitor.isValid()){
            meta.fwd.to_monitor = 8w10;             // packet going to monitor
        }             
    }

    action clone_i2e(bit<32> session_id) {
        //const bit<32> REPORT_MIRROR_SESSION_ID = 5;

        clone3(CloneType.I2E, session_id, {standard_metadata});   //REPORT_MIRROR_SESSION_ID);
        //meta.fwd.fptr = fptr;
    }

    action drop_packet() {
        mark_to_drop(standard_metadata);
    }

    action set_monitor_vars(bit<8> flow_id) {
        hdr.monitor.if_monitor = 0;
        hdr.monitor.received = 0;
        hdr.monitor.send_time = 0;
        hdr.monitor.relative_time = 0;
	if (flow_id == 1) {
            hdr.monitor.time_left = MAX_PACKET_LATENCY_1;
	}
	else if (flow_id == 2) {
	    hdr.monitor.time_left = MAX_PACKET_LATENCY_2;	
	}
        // Check if it should be a monitor packet 

        meta.fwd.time_now = standard_metadata.ingress_global_timestamp;
        r_last_monitor_time.read(meta.fwd.last_time,REGISTER_ID);
        if (meta.fwd.time_now - meta.fwd.last_time > MONITORING_INTERVAL) {
            meta.fwd.set_for_monitoring = 1;
        }
    }
    

    table set_init_monitor {
        actions = {
            set_monitor_vars;
        }
        key = {
            standard_metadata.ingress_port: exact;
        }
    }

    table cloning {
        actions = {
            clone_i2e;
        }
        key = {
            standard_metadata.ingress_port: exact;
        }
    }

    table forwarding {
        actions = {
            forward;
        }
        key = {
            //meta.fwd.fptr                 : exact;
            standard_metadata.ingress_port: exact;
            hdr.ipv4.dstAddr              : exact;
        }
    }

    apply {
        
        #ifdef ENABLE_DEBUG_TABLES
            debug_std_meta_ingress_start.apply(standard_metadata);
            my_debug_1_1.apply(hdr, meta);
        #endif  // ENABLE_DEBUG_TABLES



        if (hdr.monitor.isValid() && hdr.ipv4.totalLen > 500) {
            set_init_monitor.apply();

            if (meta.fwd.set_for_monitoring == 1 || hdr.monitor.if_monitor == 1) {
                
                if (meta.fwd.set_for_monitoring == 1) {
                    r_last_monitor_time.write(REGISTER_ID,meta.fwd.time_now);
                }

                if (hdr.monitor.received == 0 && hdr.monitor.if_monitor != 4w0) {
                    // The packet received is a monitoring packet
                    cloning.apply();
                    forwarding.apply();
                }
                else if (hdr.monitor.received != 0) {
                    // The packet received is the cloned monitored packet
                    bit<48> latency = (standard_metadata.ingress_global_timestamp - (hdr.monitor.send_time + hdr.monitor.relative_time)) >> 1;
                    r_recent_latency.write(REGISTER_ID,latency);
                    drop_packet();
                }
                else {
                    hdr.monitor.if_monitor = 4w1;
                    forwarding.apply();
                }
            }
            else {
                forwarding.apply();
            }
        }
        else {
            forwarding.apply();
        }



        #ifdef ENABLE_DEBUG_TABLES
            my_debug_1_2.apply(hdr, meta);
            debug_std_meta_ingress_end.apply(standard_metadata);
        #endif  // ENABLE_DEBUG_TABLES
        
    }
}

control DeparserImpl(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.tcp);
        packet.emit(hdr.tcp_options);
        //packet.emit(hdr.queue_delay);
        packet.emit(hdr.monitor);
        packet.emit(hdr.udp);
    }
}

V1Switch(ParserImpl(), verifyChecksum(), ingress(), egress(), computeChecksum(), DeparserImpl()) main;

