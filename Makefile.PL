use ExtUtils::MakeMaker;

my $mm = MM->new({
    dist         => {
       PREOP	=> 'pod2text SNMP.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
       COMPRESS	=> 'gzip -9v',
       SUFFIX	=> '.gz',
	            },
    NAME         => "AnyEvent::SNMP",
    VERSION_FROM => "SNMP.pm",
    PREREQ_PM    => {
       Net::SNMP => 5,
       AnyEvent  => 4.35, # TODO
    },
});

$mm->flush;

