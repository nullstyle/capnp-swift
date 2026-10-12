@0xa950cf989d1a0f36;
struct Clash(T) { value @0 :T; }
struct UsesB { box @0 :Clash(Data); }
