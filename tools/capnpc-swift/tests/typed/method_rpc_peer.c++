#include "method_generics.capnp.h"
#include <capnp/ez-rpc.h>
#include <kj/debug.h>
#include <iostream>
#include <string>

class EchoServer final: public Child::Server {
  kj::Promise<void> echo(EchoContext context) override {
    auto input = context.getParams();
    auto output = context.getResults();
    output.setScope(kj::str("ack:", input.getScope()));
    output.getValue().set(input.getValue());
    return kj::READY_NOW;
  }
};
class NamedServer final: public Named::Server {
  kj::Promise<void> echo(EchoContext context) override {
    context.getResults().getValue().set(context.getParams().getValue());
    return kj::READY_NOW;
  }
};
class SwapServer final: public Swap::Server {
  kj::Promise<void> swap(SwapContext context) override {
    auto input = context.getParams();
    auto output = context.getResults();
    output.getFirst().set(input.getSecond());
    output.getSecond().set(input.getFirst());
    return kj::READY_NOW;
  }
};
class BatchServer final: public Batch::Server {
  kj::Promise<void> gather(GatherContext context) override {
    context.getResults().setValues(context.getParams().getValues());
    return kj::READY_NOW;
  }
};

static void childClient(capnp::EzRpcClient& rpc) {
  auto client = rpc.getMain<Child>();
  auto& wait = rpc.getWaitScope();
  {
    auto request = client.echoRequest<capnp::Text>();
    request.setScope("text"); request.setValue("hello");
    auto result = request.send().wait(wait);
    KJ_REQUIRE(result.getValue() == "hello" && result.getScope() == "ack:text", "method text and outer binding");
    std::cout << "PASS: method text and outer binding\n";
  }
  {
    const uint8_t bytes[] = {0, 1, 255};
    auto request = client.echoRequest<capnp::Data>();
    request.setScope("data"); request.setValue(kj::arrayPtr(bytes, 3));
    auto result = request.send().wait(wait);
    auto value = result.getValue();
    KJ_REQUIRE(value.size() == 3 && value[0] == 0 && value[1] == 1 && value[2] == 255 && result.getScope() == "ack:data", "method data and outer binding");
    std::cout << "PASS: method data and outer binding\n";
  }
  {
    auto request = client.echoRequest<capnp::List<uint16_t>>();
    request.setScope("numbers");
    auto value = request.initValue(3); value.set(0, 7); value.set(1, 65535); value.set(2, 9);
    auto result = request.send().wait(wait);
    auto read = result.getValue();
    KJ_REQUIRE(read.size() == 3 && read[0] == 7 && read[1] == 65535 && read[2] == 9, "method integer list");
    std::cout << "PASS: method integer list\n";
  }
  {
    auto request = client.echoRequest<Box<capnp::Text>>();
    request.setScope("box"); request.initValue().setValue("inside");
    auto result = request.send().wait(wait);
    KJ_REQUIRE(result.getValue().getValue() == "inside", "method nested generic struct");
    std::cout << "PASS: method nested generic struct\n";
  }
  {
    auto request = client.echoRequest<capnp::List<Box<capnp::Text>>>();
    request.setScope("boxes");
    auto values = request.initValue(2); values[0].setValue("one"); values[1].setValue("two");
    auto result = request.send().wait(wait);
    auto read = result.getValue();
    KJ_REQUIRE(read.size() == 2 && read[0].getValue() == "one" && read[1].getValue() == "two", "method struct list");
    std::cout << "PASS: method struct list\n";
  }
  {
    auto request = client.echoRequest<Child>();
    request.setScope("cap"); request.setValue(client);
    auto returned = request.send().wait(wait).getValue();
    auto callback = returned.echoRequest<capnp::Text>();
    callback.setScope("callback"); callback.setValue("retained");
    auto result = callback.send().wait(wait);
    KJ_REQUIRE(result.getValue() == "retained" && result.getScope() == "ack:callback", "method capability remains callable");
    std::cout << "PASS: method capability remains callable\n";
  }
}
static void namedClient(capnp::EzRpcClient& rpc) {
  auto client = rpc.getMain<Named>();
  auto& wait = rpc.getWaitScope();
  auto text = client.echoRequest<capnp::Text>(); text.setValue("named");
  auto textResult = text.send().wait(wait);
  KJ_REQUIRE(textResult.getValue() == "named", "named text brand");
  std::cout << "PASS: named text brand\n";
  const uint8_t bytes[] = {9, 0, 8};
  auto data = client.echoRequest<capnp::Data>(); data.setValue(kj::arrayPtr(bytes, 3));
  auto dataResult = data.send().wait(wait);
  auto value = dataResult.getValue();
  KJ_REQUIRE(value.size() == 3 && value[0] == 9 && value[1] == 0 && value[2] == 8, "named data brand");
  std::cout << "PASS: named data brand\n";
  auto nested = client.echoRequest<Box<capnp::Text>>(); nested.initValue().setValue("nested");
  auto nestedResult = nested.send().wait(wait);
  KJ_REQUIRE(nestedResult.getValue().getValue() == "nested", "named nested brand");
  std::cout << "PASS: named nested brand\n";
}
static void swapClient(capnp::EzRpcClient& rpc) {
  auto client = rpc.getMain<Swap>();
  auto& wait = rpc.getWaitScope();
  const uint8_t bytes[] = {4, 5};
  auto request = client.swapRequest<capnp::Text, capnp::Data>();
  request.setFirst("first"); request.setSecond(kj::arrayPtr(bytes, 2));
  auto result = request.send().wait(wait);
  auto first = result.getFirst();
  KJ_REQUIRE(first.size() == 2 && first[0] == 4 && first[1] == 5 && result.getSecond() == "first", "reversed method arguments");
  std::cout << "PASS: reversed method arguments\n";
}
static void batchClient(capnp::EzRpcClient& rpc) {
  auto client = rpc.getMain<Batch>();
  auto& wait = rpc.getWaitScope();
  auto request = client.gatherRequest<capnp::Text>();
  auto values = request.initValues(2); values[0].setValue("one"); values[1].setValue("two");
  auto result = request.send().wait(wait);
  auto read = result.getValues();
  KJ_REQUIRE(read.size() == 2 && read[0].getValue() == "one" && read[1].getValue() == "two", "method arguments in list elements");
  std::cout << "PASS: method arguments in list elements\n";
}
int main(int argc, char** argv) {
  try {
    KJ_REQUIRE(argc >= 3, "usage: peer server kind [port] | peer client kind address");
    std::string mode = argv[1], kind = argv[2];
    if (mode == "server") {
      capnp::Capability::Client handler = nullptr;
      if (kind == "child") handler = kj::heap<EchoServer>();
      else if (kind == "named") handler = kj::heap<NamedServer>();
      else if (kind == "swap") handler = kj::heap<SwapServer>();
      else if (kind == "batch") handler = kj::heap<BatchServer>();
      else KJ_FAIL_REQUIRE("unknown interface");
      capnp::EzRpcServer server(kj::mv(handler), "127.0.0.1", argc > 3 ? std::stoul(argv[3]) : 0);
      auto port = server.getPort().wait(server.getWaitScope());
      std::cout << "PORT " << port << std::endl;
      kj::NEVER_DONE.wait(server.getWaitScope());
    } else {
      KJ_REQUIRE(mode == "client" && argc == 4, "invalid client command");
      capnp::EzRpcClient client(argv[3]);
      if (kind == "child") childClient(client);
      else if (kind == "named") namedClient(client);
      else if (kind == "swap") swapClient(client);
      else if (kind == "batch") batchClient(client);
      else KJ_FAIL_REQUIRE("unknown interface");
    }
    return 0;
  } catch (const kj::Exception& e) {
    std::cerr << e.getDescription().cStr() << '\n';
    return 1;
  }
}
