@0x91a7ce449e91d01b;
struct Clash(T) { value @0 :T; }
struct UsesA { box @0 :Clash(Text); }
