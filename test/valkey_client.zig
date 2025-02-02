const std = @import("std");

const resp = @import("resp");
const Client = resp.valkey.Client;

test {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 6379);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();
    var client = Client.init(stream);
    try client.hello(std.testing.allocator);
}
