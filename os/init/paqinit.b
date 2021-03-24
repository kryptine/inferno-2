implement Init;
#
# init program for Motorola PowerPAQ (serial console only)
#
include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;

include "keyring.m";
	kr: Keyring;

include "security.m";
	auth: Auth;

Init: module
{
	init:	fn();
};

Shell: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Bootpreadlen: con 128;
defserver := "200.1.1.46";	# vivido

# option switches
UseLocalFS: con 1<<0;
EtherBoot: con 1<<1;
Prompting: con 1<<3;

lfs(): int
{
	if(!flashinit("#F/flash", 1024*1024, 1024*1024))
		return -1;
	if(mountkfs("#X/ftldata", "main", "flash") < 0)
		return -1;
	if(sys->bind("#Kmain", "/n/local", sys->MREPL) < 0){
		sys->print("can't bind #Kmain to /n/local: %r\n");
		return -1;
	}
	if(sys->bind("/n/local", "/", Sys->MCREATE|Sys->MREPL) < 0){
		sys->print("can't bind /n/local after /: %r\n");
		return -1;
	}
	return 0;
}

pppstarted:= 0;

netfs(mountpt: string, server: string): int
{
	sys->print("bootp ...");

	fd := sys->open("/net/ipifc/clone", sys->OWRITE);
	if(fd == nil) {
		sys->print("init: open /net/ipifc/clone: %r\n");
		return -1;
	}

	if(server == "")
		server = defserver;

	net := "tcp";	# how to specify il?
	svcname := net + "!" + server + "!6666";
	sys->print("starting ppp to dial %s...", svcname);
	sys->sleep(5000);

	if(sys->fprint(fd, "bind ppp #t/eia0") < 0){
		sys->print("can't start ppp: %r\n");
		return -1;
	}

	(ok, c) := sys->dial(svcname, nil);
	if(ok < 0){
		sys->print("can't dial %s: %r\n", svcname);
		sys->fprint(fd, "unbind");
		sys->sleep(1000);
		return -1;
	}

	sys->print("\nConnected ...\n");
	if(kr != nil){
		err: string;
		sys->print("Authenticate ...");
		ai := kr->readauthinfo("/nvfs/default");
		if(ai == nil){
			sys->print("readauthinfo /nvfs/default failed: %r\n");
			sys->print("trying \"noauth\"\n");
			(c.dfd, err) = auth->client(Auth->NOAUTH, ai, c.dfd);
		} else
			(c.dfd, err) = auth->client(Auth->NOSSL, ai, c.dfd);
		if(err != nil){
			sys->print("authentication failed: %s\n", err);
			sys->fprint(fd, "delete serial #t/eia0");
			sys->sleep(1000);
			return -1;
		}
	}

	sys->print("mount %s...", mountpt);

	c.cfd = nil;
	n := sys->mount(c.dfd, mountpt, sys->MREPL, "");
	if(n > 0)
		return 0;
	if(n < 0){
		sys->print("%r");
		sys->fprint(fd, "unbind");
		sys->sleep(1000);
	}
	return -1;
}

addroute(ip: string)
{
	fd := sys->open("/net/iproute", Sys->OWRITE);
	if (fd == nil) {
		sys->print("can't open /net/iproute: %r");
		return;
	}
	if(sys->fprint(fd, "add 0.0.0.0 0.0.0.0 %s", ip) < 0)
		sys->print("can't set default route: %r\n");
}

init()
{
	spec: string;

	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
	if(auth != nil)
		auth->init();

	sys->print("**\n** Inferno\n** Lucent Technologies\n**\n");

	optsw := options();
	sys->print("Switch options: 0x%ux\n", optsw);

	#
	# Setup what we need to call a server and
	# Authenticate
	#
	sys->bind("#l", "/net", sys->MREPL);
	sys->bind("#I", "/net", sys->MAFTER);
	sys->bind("#c", "/dev", sys->MAFTER);

	sys->print("Non-volatile ram read ...");

	nvplaces := array[] of {
		"#H/hd0nvram",
		"/nvram.data"
	};

	nvramfd: ref sys->FD;
	for(i := 0; i < len nvplaces; i++) {
		nvramfd = sys->open(nvplaces[i], sys->ORDWR);
		if(nvramfd != nil)
			break;
	}

	if(nvramfd != nil) {
		spec = sys->sprint("#F%d", nvramfd.fd);
		if(sys->bind(spec, "/nvfs", sys->MAFTER) < 0)
			sys->print("init: bind %s: %r\n", spec);

		sys->print("mounted tinyfs");
	}

	fsready := 0;
	mountpt := "/";
	usertc := 0;

	if((optsw & Prompting) == 0){
		if(optsw & UseLocalFS){
			sys->print("Option: use local file system\n");
			if(lfs() == 0){
				fsready = 1;
				mountpt = "/n/remote";
			}
		}
	}

	mountkbd := 0;

	if(fsready == 0){

		sys->print("\n\n");

		stdin := sys->fildes(0);
		buf := array[128] of byte;
		sources := "fs" :: "net" :: nil;

		loop: for(;;) {
			sys->print("root from (");
			cm := "";
			for(l := sources; l != nil; l = tl l){
				sys->print("%s%s", cm, hd l);
				cm = ",";
			}
			sys->print(")[%s] ", hd sources);

			n := sys->read(stdin, buf, len buf);
			if(n <= 0)
				continue;
			if(buf[n-1] == byte '\n')
				n--;

			(nil, choice) := sys->tokenize(string buf[0:n], "\t ");

			if(choice == nil)
				choice = sources;
			opt := hd choice;
			case opt {
			* =>
				sys->print("\ninvalid boot option: '%s'\n", opt);
				break;
			"fs" or "" =>
				if(lfs() == 0){
					usertc = 1;
					break loop;
				}
			"net" =>
				server := "";
				if(tl choice != nil)
					server = hd tl choice;
				if(netfs("/", server) == 0){
					mountkbd = 1;
					break loop;
				}
			}
		}
	}

	#
	# default namespace
	#
	if(mountkbd && sys->bind("/dev", "/n/remote", sys->MREPL) < 0)
		sys->print("can't bind /dev /n/remote: %r\n");
	sys->unmount(nil, "/dev");
	sys->bind("#c", "/dev", sys->MBEFORE);			# console
	if(spec != nil)
		sys->bind(spec, "/nvfs", sys->MBEFORE|sys->MCREATE);	# our keys
	sys->bind("#l", "/net", sys->MBEFORE);		# ethernet
	sys->bind("#I", "/net", sys->MBEFORE);		# TCP/IP
	sys->bind("#p", "/prog", sys->MREPL);		# prog device

	setsysname();

	sys->print("clock...\n");
	setclock(usertc, mountpt);

	sys->print("Console...\n");
	if(mountkbd){
		if(sys->bind("/n/remote/keyboard", "/dev/keyboard", sys->MREPL) < 0)
			sys->print("can't bind /n/remote/keyboard: %r\n");
		if(sys->bind("/n/remote/cons", "/dev/cons", sys->MREPL) < 0)
			sys->print("can't bind /n/remote/cons: %r\n");
		save := 2 :: nil;
		infd := sys->open("/dev/cons", Sys->OREAD);
		if(infd == nil)
			sys->print("can't open(r) /dev/cons: %r\n");
		else
			save = infd.fd :: save;
		outfd := sys->open("/dev/cons", Sys->OWRITE);
		if(outfd == nil)
			sys->print("can't open(w) /dev/cons: %r\n");
		else
			save = outfd.fd :: save;
		if(infd != nil && outfd != nil){
			sys->pctl(Sys->NEWFD, save);	# save console
			if(infd != nil){
				sys->dup(infd.fd, 0);
				infd = nil;
			}
			if(outfd != nil){
				sys->dup(outfd.fd, 1);
				outfd = nil;
			}
		}
	}

	shell := load Shell "/dis/sh.dis";
	if(shell == nil) {
		sys->print("init: load /dis/sh.dis: %r");
		exit;
	}
	dc: ref Draw->Context;
	shell->init(dc, nil);
}

setclock(usertc: int, timedir: string)
{
	now := 0;
	if(usertc){
		fd := sys->open("#r/rtc", Sys->OREAD);
		if(fd != nil){
			b := array[64] of byte;
			n := sys->read(fd, b, len b-1);
			if(n > 0){
				b[n] = byte 0;
				now = int string b;
				if(now <= 16r20000000)
					now = 0;	# rtc itself is not initialised
			}
		}
	}
	if(now == 0){
		(ok, dir) := sys->stat(timedir);
		if (ok < 0) {
			sys->print("init: stat %s: %r", timedir);
			return;
		}
		now = dir.atime;
	}
	fd := sys->open("/dev/time", sys->OWRITE);
	if (fd == nil) {
		sys->print("init: can't open /dev/time: %r");
		return;
	}

	# Time is kept as microsecs, atime is in secs
	b := array of byte sys->sprint("%ud000000", now);
	if (sys->write(fd, b, len b) != len b)
		sys->print("init: can't write /dev/time: %r");
}

#
# Set system name from nvram
#
setsysname()
{
	fd := sys->open("/nvfs/ID", sys->OREAD);
	if(fd == nil)
		return;
	fds := sys->open("/dev/sysname", sys->OWRITE);
	if(fds == nil)
		return;
	buf := array[128] of byte;
	nr := sys->read(fd, buf, len buf);
	if(nr <= 0)
		return;
	sys->write(fds, buf, nr);
}

#
# fetch options from switch DS2
#
options(): int
{
	fd := sys->open("#r/switch", Sys->OREAD);
	if(fd == nil){
		sys->print("can't open #r/switch: %r\n");
		return 0;
	}
	b := array[20] of byte;
	n := sys->read(fd, b, len b);
	s := string b[0:n];
	return int s;
}

bootp(): string
{
	fd := sys->open("/net/bootp", sys->OREAD);
	if(fd == nil) {
		sys->print("init: can't open /net/bootp: %r");
		return nil;
	}

	buf := array[Bootpreadlen] of byte;
	nr := sys->read(fd, buf, len buf);
	fd = nil;
	if(nr <= 0) {
		sys->print("init: read /net/bootp: %r");
		return nil;
	}

	(ntok, ls) := sys->tokenize(string buf, " \t\n");
	while(ls != nil) {
		if(hd ls == "fsip"){
			ls = tl ls;
			break;
		}
		ls = tl ls;
	}
	if(ls == nil) {
		sys->print("init: server address not in bootp read");
		return nil;
	}

	srv := hd ls;

	sys->print("%s\n", srv);

	return srv;
}

#
# set up flash translation layer
#
flashdone := 0;

flashinit(flashmem: string, offset: int, length: int): int
{
	if(flashdone)
		return 1;
	sys->print("Set flash translation of %s at offset %d (%d bytes)\n", flashmem, offset, length);
	fd := sys->open("#X/ftlctl", Sys->OWRITE);
	if(fd == nil){
		sys->print("can't open #X/ftlctl: %r\n");
		return 0;
	}
	if(sys->fprint(fd, "init %s %ud %ud", flashmem, offset, length) <= 0){
		sys->print("can't init flash translation: %r");
		return 0;
	}
	flashdone = 1;
	return 1;
}

#
# Mount kfs filesystem
#
mountkfs(devname: string, fsname: string, options: string): int
{
	fd := sys->open("#Kcons/kfsctl", sys->OWRITE);
	if(fd == nil) {
		sys->print("could not open #Kcons/kfsctl: %r\n");
		return -1;
	}
	if(sys->fprint(fd, "filsys %s %s %s", fsname, devname, options) <= 0){
		sys->print("could not write #Kcons/kfsctl: %r\n");
		return -1;
	}
	if(options == "ro")
		sys->fprint(fd, "cons flashwrite");
	return 0;
}