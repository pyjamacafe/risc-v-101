// GDB remote-protocol server for the Verilated RV32I bare CPU (core + memory).
//
// Lets riscv64-elf-gdb connect to the actual RTL simulation with:
//   target remote :3333
// and then load programs, set breakpoints, single-step, and read/write
// registers and memory. The simulation is single-cycle, so one clock step
// == one instruction step.
//
// Usage:  ./obj_gdb_bare/rv32i_gdb_bare [port]     (default port 3333)

#include "Vrv32i_gdb_bare.h"
#include "verilated.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <unistd.h>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vrv32i_gdb_bare* top;

// ------------------------------------------------------------------
// tiny hex helpers
// ------------------------------------------------------------------
static int hexv(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}
static std::string hex8(uint32_t v) {          // 4 bytes, little endian
    const char* d = "0123456789abcdef";
    std::string s;
    for (int i = 0; i < 4; i++) {
        uint8_t b = v >> (8 * i);
        s += d[(b >> 4) & 0xf];
        s += d[b & 0xf];
    }
    return s;
}
static std::string hexb(uint8_t b) {
    const char* d = "0123456789abcdef";
    return std::string() + d[(b >> 4) & 0xf] + d[b & 0xf];
}
// Parse a 2*n-hex-char string as little-endian bytes (remote protocol order).
static uint32_t hex_word(const std::string& h) {
    uint32_t v = 0;
    for (int i = 0; i < 4 && 2 * i + 1 < (int)h.size(); i++) {
        uint8_t b = (uint8_t)(hexv(h[2 * i]) * 16 + hexv(h[2 * i + 1]));
        v |= (uint32_t)b << (8 * i);
    }
    return v;
}

// ------------------------------------------------------------------
// sockets
// ------------------------------------------------------------------
static int listen_fd = -1;
static int client_fd = -1;
static std::string rxbuf;

static void send_raw(const std::string& s) {
    if (client_fd >= 0) ::send(client_fd, s.data(), s.size(), 0);
}

// Send a GDB packet "$payload#cs".
static void send_packet(const std::string& payload) {
    unsigned cs = 0;
    for (char c : payload) cs = (cs + (unsigned char)c) & 0xff;
    std::string pkt = "$" + payload + "#" + hexb((uint8_t)cs);
    send_raw(pkt);
}

// Read one packet payload if a complete "$...#xx" is buffered; else "".
static std::string poll_packet() {
    char buf[4096];
    ssize_t n = ::recv(client_fd, buf, sizeof(buf), 0);
    if (n > 0) rxbuf.append(buf, n);
    // discard leading junk until '$'
    size_t start = rxbuf.find('$');
    if (start == std::string::npos) {
        if (rxbuf.size() > 4096) rxbuf.clear();
        return "";
    }
    rxbuf.erase(0, start + 1);
    size_t hash = rxbuf.find('#');
    if (hash == std::string::npos) return "";
    if (hash + 2 >= rxbuf.size()) return "";          // checksum not here yet
    std::string payload = rxbuf.substr(0, hash);
    unsigned cs = hexv(rxbuf[hash + 1]) * 16 + hexv(rxbuf[hash + 2]);
    rxbuf.erase(0, hash + 3);
    unsigned calc = 0;
    for (char c : payload) calc = (calc + (unsigned char)c) & 0xff;
    send_raw(cs == calc ? "+" : "-");
    return cs == calc ? payload : "";
}

// ------------------------------------------------------------------
// model access
// ------------------------------------------------------------------
static void clk_tick() {
    top->clk = 1;
    top->eval();
    top->clk = 0;
    top->eval();
}

static uint32_t read_reg(int n) {
    if (n >= 0 && n < 32) {
        top->dbg_reg_ridx = n;
        top->eval();
        return top->dbg_reg_rval;
    }
    if (n == 32) return top->dbg_pc;
    return 0;                                          // fpu regs (none)
}

static void write_reg(int n, uint32_t v) {
    if (n >= 0 && n < 32 && n != 0) {                  // x0 is read-only
        top->dbg_reg_we = 1;
        top->dbg_reg_widx = n;
        top->dbg_reg_wval = v;
        clk_tick();
        top->dbg_reg_we = 0;
        top->eval();
    } else if (n == 32) {
        top->dbg_pc_we = 1;
        top->dbg_pc_wval = v;
        clk_tick();
        top->dbg_pc_we = 0;
        top->eval();
    }
}

static uint32_t read_mem_word(uint32_t addr) {
    top->dbg_peek_addr = addr;
    top->eval();
    return top->dbg_peek_data;
}

static void write_mem_byte(uint32_t addr, uint8_t b) {
    top->dbg_mem_waddr = addr;
    top->dbg_mem_wdata = b;
    top->dbg_mem_wen   = 1;
    clk_tick();                                        // dbg_hold is high
    top->dbg_mem_wen   = 0;
    top->eval();
}

// ------------------------------------------------------------------
// GDB state
// ------------------------------------------------------------------
enum Mode { STOPPED, RUNNING, STEPPING };
static Mode mode = STOPPED;
static std::vector<uint32_t> breakpoints;
static bool detached = false;

static bool has_bp(uint32_t pc) {
    for (uint32_t a : breakpoints) if (a == pc) return true;
    return false;
}

static void go_stopped() {
    mode = STOPPED;
    top->dbg_hold = 1;
    top->eval();
}

// ------------------------------------------------------------------
// target description (qXfer)
// ------------------------------------------------------------------
static const char* TARGET_XML =
    "<?xml version=\"1.0\"?>\n"
    "<target version=\"1.0\">\n"
    "  <architecture>riscv:rv32</architecture>\n"
    "  <feature name=\"org.gnu.gdb.riscv.cpu\">\n"
    "    <reg name=\"zero\" bitsize=\"32\" type=\"int\"      regnum=\"0\"  group=\"general\"/>\n"
    "    <reg name=\"ra\"   bitsize=\"32\" type=\"code_ptr\" regnum=\"1\"  group=\"general\"/>\n"
    "    <reg name=\"sp\"   bitsize=\"32\" type=\"data_ptr\" regnum=\"2\"  group=\"general\"/>\n"
    "    <reg name=\"gp\"   bitsize=\"32\" type=\"data_ptr\" regnum=\"3\"  group=\"general\"/>\n"
    "    <reg name=\"tp\"   bitsize=\"32\" type=\"data_ptr\" regnum=\"4\"  group=\"general\"/>\n"
    "    <reg name=\"t0\"   bitsize=\"32\" type=\"int\"      regnum=\"5\"  group=\"general\"/>\n"
    "    <reg name=\"t1\"   bitsize=\"32\" type=\"int\"      regnum=\"6\"  group=\"general\"/>\n"
    "    <reg name=\"t2\"   bitsize=\"32\" type=\"int\"      regnum=\"7\"  group=\"general\"/>\n"
    "    <reg name=\"s0\"   bitsize=\"32\" type=\"int\"      regnum=\"8\"  group=\"general\"/>\n"
    "    <reg name=\"s1\"   bitsize=\"32\" type=\"int\"      regnum=\"9\"  group=\"general\"/>\n"
    "    <reg name=\"a0\"   bitsize=\"32\" type=\"int\"      regnum=\"10\" group=\"general\"/>\n"
    "    <reg name=\"a1\"   bitsize=\"32\" type=\"int\"      regnum=\"11\" group=\"general\"/>\n"
    "    <reg name=\"a2\"   bitsize=\"32\" type=\"int\"      regnum=\"12\" group=\"general\"/>\n"
    "    <reg name=\"a3\"   bitsize=\"32\" type=\"int\"      regnum=\"13\" group=\"general\"/>\n"
    "    <reg name=\"a4\"   bitsize=\"32\" type=\"int\"      regnum=\"14\" group=\"general\"/>\n"
    "    <reg name=\"a5\"   bitsize=\"32\" type=\"int\"      regnum=\"15\" group=\"general\"/>\n"
    "    <reg name=\"a6\"   bitsize=\"32\" type=\"int\"      regnum=\"16\" group=\"general\"/>\n"
    "    <reg name=\"a7\"   bitsize=\"32\" type=\"int\"      regnum=\"17\" group=\"general\"/>\n"
    "    <reg name=\"s2\"   bitsize=\"32\" type=\"int\"      regnum=\"18\" group=\"general\"/>\n"
    "    <reg name=\"s3\"   bitsize=\"32\" type=\"int\"      regnum=\"19\" group=\"general\"/>\n"
    "    <reg name=\"s4\"   bitsize=\"32\" type=\"int\"      regnum=\"20\" group=\"general\"/>\n"
    "    <reg name=\"s5\"   bitsize=\"32\" type=\"int\"      regnum=\"21\" group=\"general\"/>\n"
    "    <reg name=\"s6\"   bitsize=\"32\" type=\"int\"      regnum=\"22\" group=\"general\"/>\n"
    "    <reg name=\"s7\"   bitsize=\"32\" type=\"int\"      regnum=\"23\" group=\"general\"/>\n"
    "    <reg name=\"s8\"   bitsize=\"32\" type=\"int\"      regnum=\"24\" group=\"general\"/>\n"
    "    <reg name=\"s9\"   bitsize=\"32\" type=\"int\"      regnum=\"25\" group=\"general\"/>\n"
    "    <reg name=\"s10\"  bitsize=\"32\" type=\"int\"      regnum=\"26\" group=\"general\"/>\n"
    "    <reg name=\"s11\"  bitsize=\"32\" type=\"int\"      regnum=\"27\" group=\"general\"/>\n"
    "    <reg name=\"t3\"   bitsize=\"32\" type=\"int\"      regnum=\"28\" group=\"general\"/>\n"
    "    <reg name=\"t4\"   bitsize=\"32\" type=\"int\"      regnum=\"29\" group=\"general\"/>\n"
    "    <reg name=\"t5\"   bitsize=\"32\" type=\"int\"      regnum=\"30\" group=\"general\"/>\n"
    "    <reg name=\"t6\"   bitsize=\"32\" type=\"int\"      regnum=\"31\" group=\"general\"/>\n"
    "    <reg name=\"pc\"   bitsize=\"32\" type=\"code_ptr\" regnum=\"32\" group=\"general\"/>\n"
    "  </feature>\n"
    "</target>\n";

// Escape GDB binary bytes ($ # } + - become 0x7d 0x..^0x20).
static std::string xfer_escape(const std::string& s) {
    std::string out;
    for (unsigned char c : s) {
        if (c == '#' || c == '$' || c == '}' || c == '+' || c == '-') {
            out += (char)0x7d;
            out += (char)(c ^ 0x20);
        } else {
            out += (char)c;
        }
    }
    return out;
}

static unsigned parse_hexnum(const std::string& s, size_t& i) {
    unsigned v = 0;
    while (i < s.size() && isxdigit((unsigned char)s[i])) {
        v = v * 16 + hexv(s[i++]);
    }
    return v;
}

// ------------------------------------------------------------------
// command dispatch (CPU is stopped)
// ------------------------------------------------------------------
static void handle_packet(const std::string& p) {
    if (getenv("GDB_DEBUG")) fprintf(stderr, "stub << %s\n", p.c_str());
    if (p == "?") { send_packet("S05"); return; }

    if (p[0] == 'g') {                                // read all registers
        std::string out;
        for (int n = 0; n <= 32; n++) out += hex8(read_reg(n));
        send_packet(out);
        return;
    }
    if (p[0] == 'G') {                                // write all registers
        size_t i = 1;
        for (int n = 0; n <= 32; n++) {
            if (i + 8 <= p.size()) write_reg(n, hex_word(p.substr(i, 8)));
            i += 8;
        }
        send_packet("OK");
        return;
    }
    if (p[0] == 'p') {                                // read one register
        send_packet(hex8(read_reg((int)strtol(p.c_str() + 1, NULL, 16))));
        return;
    }
    if (p[0] == 'P') {                                // write one register
        size_t eq = p.find('=');
        int n = (int)strtol(p.substr(1, eq - 1).c_str(), NULL, 16);
        uint32_t v = hex_word(p.substr(eq + 1));
        write_reg(n, v);
        send_packet("OK");
        return;
    }
    if (p[0] == 'm') {                                // read memory
        size_t i = 1;
        uint32_t addr = parse_hexnum(p, i);
        if (p[i] == ',') i++;
        uint32_t len = parse_hexnum(p, i);
        std::string out;
        for (uint32_t k = 0; k < len; k++)
            out += hexb((uint8_t)(read_mem_word(addr + k) & 0xff));
        send_packet(out);
        return;
    }
    if (p[0] == 'M') {                                // write memory (hex)
        size_t i = 1;
        uint32_t addr = parse_hexnum(p, i);
        if (p[i] == ',') i++;
        uint32_t len = parse_hexnum(p, i);
        if (p[i] == ':') i++;
        for (uint32_t k = 0; k < len && i + 1 < p.size(); k++) {
            write_mem_byte(addr + k, (uint8_t)(hexv(p[i]) * 16 + hexv(p[i + 1])));
            i += 2;
        }
        send_packet("OK");
        return;
    }
    if (p[0] == 'X') {                                // write memory (binary)
        size_t i = 1;
        uint32_t addr = parse_hexnum(p, i);
        if (p[i] == ',') i++;
        uint32_t len = parse_hexnum(p, i);
        if (p[i] == ':') i++;
        uint32_t written = 0;
        while (written < len && i < p.size()) {
            unsigned char c = p[i++];
            if (c == 0x7d) c = (unsigned char)p[i++] ^ 0x20;   // escaped
            write_mem_byte(addr + written, (uint8_t)c);
            written++;
        }
        send_packet("OK");
        return;
    }

    if (p[0] == 'c') {                                // continue
        if (p.size() > 1) write_reg(32, (uint32_t)strtoul(p.c_str() + 1, NULL, 16));
        top->dbg_hold = 0;
        mode = RUNNING;
        return;                                       // reply when we stop
    }
    if (p[0] == 's') {                                // single step
        if (p.size() > 1) write_reg(32, (uint32_t)strtoul(p.c_str() + 1, NULL, 16));
        top->dbg_hold = 0;
        mode = STEPPING;
        return;                                       // reply when step done
    }

    if (p.rfind("Z0,", 0) == 0) {                     // insert breakpoint
        size_t i = 2;
        parse_hexnum(p, i); if (p[i] == ',') i++;
        breakpoints.push_back(parse_hexnum(p, i));
        send_packet("OK");
        return;
    }
    if (p.rfind("z0,", 0) == 0) {                     // remove breakpoint
        size_t i = 2;
        parse_hexnum(p, i); if (p[i] == ',') i++;
        uint32_t a = parse_hexnum(p, i);
        for (auto it = breakpoints.begin(); it != breakpoints.end(); ++it)
            if (*it == a) { breakpoints.erase(it); break; }
        send_packet("OK");
        return;
    }

    if (p[0] == 'H') { send_packet("OK"); return; }   // thread ops
    if (p[0] == 'D') { send_packet("OK"); detached = true; return; }
    if (p == "k") {                                 // kill -> reset, stay alive
        breakpoints.clear();
        go_stopped();
        detached = true;
        return;
    }

    if (p.rfind("qSupported", 0) == 0) {
        send_packet("PacketSize=4000;qXfer:features:read+");
        return;
    }
    if (p.rfind("qXfer:features:read:target.xml:", 0) == 0) {
        size_t colon = p.rfind(':');
        size_t comma = p.find(',', colon);
        unsigned off = (unsigned)strtoul(p.substr(colon + 1, comma - colon - 1).c_str(), NULL, 16);
        unsigned len = (unsigned)strtoul(p.substr(comma + 1).c_str(), NULL, 16);
        std::string xml(TARGET_XML);
        std::string chunk;
        bool more = false;
        if (off < xml.size()) {
            chunk = xfer_escape(xml.substr(off, len));
            more = (off + len) < xml.size();
        }
        send_packet(std::string(more ? "m" : "l") + chunk);
        return;
    }
    if (p.rfind("qAttached", 0) == 0) { send_packet("0"); return; }

    send_packet("");                                  // unsupported
}

// ------------------------------------------------------------------
// main
// ------------------------------------------------------------------
int main(int argc, char** argv) {
    int port = 3333;
    if (argc > 1) port = atoi(argv[1]);

    Verilated::commandArgs(argc, argv);
    top = new Vrv32i_gdb_bare;

    // reset the CPU (the first eval() runs the RTL initial blocks)
    top->rst = 1;
    top->clk = 0;
    top->eval();
    clk_tick();
    clk_tick();
    top->rst = 0;
    top->dbg_hold = 1;                                // start halted
    top->eval();

    signal(SIGPIPE, SIG_IGN);

    // listen
    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)port);
    if (bind(listen_fd, (sockaddr*)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "bind failed on port %d\n", port);
        return 1;
    }
    listen(listen_fd, 1);
    printf("GDB stub ready on 127.0.0.1:%d  (gdb: target remote :%d)\n", port, port);
    fflush(stdout);

    client_fd = accept(listen_fd, NULL, NULL);
    if (client_fd < 0) return 1;
    printf("gdb connected\n");
    fflush(stdout);

    // main loop: poll socket, run CPU
    while (true) {
        // wait for / re-accept a gdb connection
        while (detached) {
            ::close(client_fd);
            printf("gdb detached; waiting for a new connection\n");
            fflush(stdout);
            client_fd = accept(listen_fd, NULL, NULL);
            detached = false;
            printf("gdb connected\n");
            fflush(stdout);
        }

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(client_fd, &rfds);
        timeval tv{};
        tv.tv_sec = 0;
        tv.tv_usec = 100;                             // 100 us poll
        int s = select(client_fd + 1, &rfds, NULL, NULL, &tv);

        if (s > 0) {
            char probe;
            ssize_t n = ::recv(client_fd, &probe, 1, MSG_PEEK);
            if (n == 0) {                             // gdb closed the socket
                ::close(client_fd);
                client_fd = accept(listen_fd, NULL, NULL);
                printf("gdb connected\n");
                fflush(stdout);
                continue;
            }
            if (n == 1 && probe == 0x03 && mode != STOPPED) {
                ::recv(client_fd, &probe, 1, 0);      // consume
                go_stopped();
                send_packet("S02");                   // SIGINT
                continue;
            }
            std::string pkt;
            while (mode == STOPPED && !(pkt = poll_packet()).empty())
                handle_packet(pkt);
        }

        if (mode == RUNNING || mode == STEPPING) {
            if (mode == RUNNING && has_bp(top->dbg_pc)) {
                go_stopped();
                send_packet("S05");                   // breakpoint
                continue;
            }
            clk_tick();                               // one instruction
            if (mode == STEPPING) {
                go_stopped();
                send_packet("S05");
            }
        }
    }
    return 0;
}