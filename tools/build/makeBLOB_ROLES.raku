#!/usr/bin/env raku

# This script reads the native_array.pm6 file, and generates the intarray,
# numarray and strarray roles in it, and writes it back to the file.

# always use highest version of Raku
use v6.*;

my $generator = $*PROGRAM-NAME;
my $generated = DateTime.now.gist.subst(/\.\d+/,'');
my $start     = '#- start of generated part of Blob ';
my $idpos     = $start.chars;
my $idchars   = 3;
my $end       = '#- end of generated part of Blob ';

# slurp the whole file and set up writing to it
my $filename = "src/core.c/Buf.pm6";
my @lines = $filename.IO.lines;
$*OUT = $filename.IO.open(:w);

my %type_mapper = (
  Signed => ( :name<SignedBlob>,
              :postfix<i>,
              :containerize(''),
            ).Map,
  Unsigned => ( :name<UnsignedBlob>,
                :postfix<u>,
                :containerize('my $ = '),
              ).Map,
);


# for all the lines in the source that don't need special handling
while @lines {
    my $line := @lines.shift;

    # nothing to do yet
    unless $line.starts-with($start) {
        say $line;
        next;
    }

    my $type = $line.substr($idpos).words.head;

    # found header, check validity and set up mapper
    die "Don't know how to handle $type"
      unless my %mapper := %type_mapper{$type};

    say $start ~ $type ~ " role -------------------------------";
    say "#- Generated on $generated by $generator";
    say "#- PLEASE DON'T CHANGE ANYTHING BELOW THIS LINE";

    # skip the old version of the code
    while @lines {
        last if @lines.shift.starts-with($end);
    }
    # spurt the role
    say Q:to/SOURCE/.subst(/ '#' (\w+) '#' /, -> $/ { %mapper{$0} }, :g).chomp;

my role #name#[::T] is repr('VMArray') is array_type(T) is implementation-detail {
    method !push-list(\action,\to,\from) {
        if nqp::istype(from,List) {
            my Mu $from := nqp::getattr(from,List,'$!reified');
            if nqp::defined($from) {
                my int $elems = nqp::elems($from);
                my int $j     = nqp::elems(to);
                nqp::setelems(to, $j + $elems);  # presize for efficiency
                my int $i = -1;
                my $got;
                nqp::while(
                  nqp::islt_i(++$i,$elems),
                  nqp::stmts(
                    ($got = nqp::atpos($from,$i)),
                    nqp::istype(nqp::hllize($got),Int)
                      ?? nqp::bindpos_#postfix#(to,$j++,$got)
                      !! self!fail-typecheck-element(action,$i,$got).throw))
            }
        }
        else {
            my $iter := from.iterator;
            my int $i = 0;
            nqp::until(
              nqp::eqaddr((my $got := $iter.pull-one),IterationEnd),
              nqp::if(
                nqp::istype(nqp::hllize($got),Int),
                nqp::stmts(
                  nqp::push_i(to,#containerize#$got),
                  ++$i
                ),
                self!fail-typecheck-element(action,$i,$got).throw
              )
            )
        }
        to
    }
    method !spread(\to,\from) {
        if nqp::elems(from) -> int $values { # something to init with
            my int $elems = nqp::elems(to) - $values;
            my int $i     = -$values;
            nqp::splice(to,from,$i,$values)
              while nqp::isle_i($i = $i + $values,$elems);

            if nqp::isgt_i($i,$elems) {  # something left to init
                --$i;                    # went one too far
                $elems = $elems + $values;
                my int $j = -1;
                if from.^array_type.^unsigned {
                    nqp::bindpos_#postfix#(to,$i,nqp::atpos_u(from, $j = ($j + 1) % $values))
                      while nqp::islt_i(++$i,$elems);
                }
                else {
                    nqp::bindpos_#postfix#(to,$i,nqp::atpos_i(from, $j = ($j + 1) % $values))
                      while nqp::islt_i(++$i,$elems);
                }
            }
        }
        to
    }
    multi method allocate(::?CLASS:U: Int:D $elements, int $value) {
        my int $elems = $elements;
        my $blob     := nqp::setelems(nqp::create(self),$elems);
        my int $i     = -1;
        nqp::bindpos_#postfix#($blob,$i,$value) while nqp::islt_i(++$i,$elems);
        $blob;
    }
    multi method AT-POS(::?ROLE:D: int \pos) {
        nqp::isge_i(pos,nqp::elems(self)) || nqp::islt_i(pos,0)
          ?? self!fail-range(pos)
          !! nqp::atpos_#postfix#(self,pos)
    }
    multi method AT-POS(::?ROLE:D: Int:D \pos) {
        nqp::isge_i(pos,nqp::elems(self)) || nqp::islt_i(pos,0)
          ?? self!fail-range(pos)
          !! nqp::atpos_#postfix#(self,pos)
    }

    multi method list(::?ROLE:D:) {
        my int $elems = nqp::elems(self);

        # presize memory, but keep it empty, so we can just push
        my $buffer := nqp::setelems(
          nqp::setelems(nqp::create(IterationBuffer),$elems),
          0
        );

        my int $i = -1;
        nqp::while(
          nqp::islt_i(++$i,$elems),
          nqp::push($buffer,nqp::atpos_#postfix#(self,$i))
        );
        $buffer.List
    }

    method reverse(::?CLASS:D:) {
        my int $elems = nqp::elems(self);
        my int $last  = nqp::sub_i($elems,1);
        my $reversed := nqp::setelems(nqp::create(self),$elems);
        my int $i     = -1;
        nqp::while(
          nqp::islt_i(++$i,$elems),
          nqp::bindpos_#postfix#($reversed,nqp::sub_i($last,$i),
            nqp::atpos_#postfix#(self,$i))
        );
        $reversed
    }

    method COMPARE(::?CLASS:D: ::?CLASS:D \other) is implementation-detail {
        nqp::unless(
          nqp::cmp_i(
            (my int $elems = nqp::elems(self)),
            nqp::elems(my $other := nqp::decont(other))
          ),
          nqp::stmts(                            # same number of elements
            (my int $i = -1),
            nqp::while(
              nqp::islt_i(++$i,$elems)
                && nqp::not_i(
                     nqp::cmp_i(nqp::atpos_#postfix#(self,$i),nqp::atpos_#postfix#($other,$i))
                   ),
              nqp::null
            ),
            nqp::if(
              nqp::isne_i($i,$elems),
              nqp::cmp_i(nqp::atpos_#postfix#(self,$i),nqp::atpos_#postfix#($other,$i))
            )
          )
        )
    }

    method SAME(::?CLASS:D: Blob:D \other) is implementation-detail {
        nqp::if(
          nqp::iseq_i(
            (my int $elems = nqp::elems(self)),
            nqp::elems(my $other := nqp::decont(other))
          ),
          nqp::stmts(                            # same number of elements
            (my int $i = -1),
            nqp::while(
              nqp::islt_i(++$i,$elems)
                && nqp::iseq_i(nqp::atpos_#postfix#(self,$i),nqp::atpos_#postfix#($other,$i)),
              nqp::null
            ),
            nqp::iseq_i($i,$elems)
          )
        )
    }

    method join(::?CLASS:D: $delim = '') {
        my int $elems = nqp::elems(self);
        my int $i     = -1;
        my $list := nqp::setelems(nqp::setelems(nqp::list_s,$elems),0);

        nqp::while(
          nqp::islt_i(++$i,$elems),
          nqp::push_s($list,nqp::atpos_#postfix#(self,$i))
        );

        nqp::join($delim.Str,$list)
    }
}

SOURCE

    # we're done for this role
    say "#- PLEASE DON'T CHANGE ANYTHING ABOVE THIS LINE";
    say $end ~ $type ~ " role ---------------------------------";
}

# close the file properly
$*OUT.close;

# vim: expandtab sw=4
