package Devel::Optic;

# ABSTRACT: Production safe data inspector

use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(looks_like_number);
use Ref::Util qw(is_ref is_arrayref is_hashref is_scalarref is_coderef is_regexpref);

use Sub::Info qw(sub_info);

use PadWalker qw(peek_my);

use Devel::Optic::Lens::Perlish;

use constant {
    DEFAULT_SCALAR_TRUNCATION_SIZE => 256,
    DEFAULT_SCALAR_SAMPLE_SIZE => 64,
    DEFAULT_SAMPLE_COUNT => 4,
};

sub new {
    my ($class, %params) = @_;
    my $uplevel = $params{uplevel} // 1;

    if (!$uplevel || !looks_like_number($uplevel) || $uplevel < 1) {
        croak "uplevel should be integer >= 1, not '$uplevel'";
    }

    my $self = {
        uplevel => $uplevel,

        # substr size for scalar subjects
        scalar_truncation_size => $params{scalar_truncation_size} // DEFAULT_SCALAR_TRUNCATION_SIZE,

        # when building a sample, how much of each scalar child to substr
        scalar_sample_size => $params{scalar_sample_size} // DEFAULT_SCALAR_SAMPLE_SIZE,

        # how many keys or indicies to display in a sample from a hashref/arrayref
        sample_count => $params{sample_count} // DEFAULT_SAMPLE_COUNT,

        lens => $params{lens} // Devel::Optic::Lens::Perlish->new,
    };

    bless $self, $class;
}

sub inspect {
    my ($self, $query) = @_;
    my $scope = peek_my($self->{uplevel});
    my $full_picture = $self->{lens}->inspect($scope, $query);
    return $self->fit_to_view($full_picture);
}

# This sub is effectively a very basic serializer. It could probably be made
# much more information-dense by adopting strategies from real serializers, or
# by incorporating hints from the user on their desired space<->thoroughness
# tradeoff.
sub fit_to_view {
    my ($self, $subject) = @_;

    my $ref = ref $subject;
    my $reasonably_summarized_with_substr = !is_ref($subject) || is_regexpref($subject) || is_scalarref($subject);

    if ($reasonably_summarized_with_substr) {
        if (!defined $subject) {
            return "(undef)";
        }

        if ($subject eq "") {
            return '"" (len 0)';
        }

        $subject = $$subject if is_scalarref($subject);
        my $scalar_truncation_size = $self->{scalar_truncation_size};
        my $len = length $subject;

        # simple scalars we can truncate (PadWalker always returns refs, so
        # this is pretty safe from accidentally substr-ing an array or hash).
        # Also, once we know we're dealing with a gigantic string (or
        # number...), we can trim much more aggressively without hurting user
        # understanding too much.

        if ($len <= $scalar_truncation_size) {
            return sprintf(
                "%s%s (len %d)",
                $ref ? "$ref " : "",
                $subject,
                $len,
            );
        }

        return sprintf(
            "%s%s (truncated to len %d; len %d)",
            $ref ? "$ref " : "",
            substr($subject, 0, $scalar_truncation_size) . "...",
            $scalar_truncation_size,
            $len,
        );
    }

    my $sample_count = $self->{sample_count};
    my $scalar_sample_size = $self->{scalar_sample_size};
    my $sample_text = "(no sample)";
    if (is_hashref($subject)) {
        my @sample;
        my @keys = keys %$subject;
        my $key_count = scalar @keys;
        $sample_count = $key_count > $sample_count ? $sample_count : $key_count;
        my @sample_keys = @keys[0 .. $sample_count - 1];
        for my $key (@sample_keys) {
            my $val = $subject->{$key};
            my $val_chunk;
            if (ref $val) {
                $val_chunk = ref $val;
            } elsif (!defined $val) {
                $val_chunk = '(undef)';
            } else {
                $val_chunk = substr($val, 0, $scalar_sample_size);
                $val_chunk .= '...' if length($val_chunk) < length($val);
            }
            my $key_chunk = substr($key, 0, $scalar_sample_size);
            $key_chunk .= '...' if length($key_chunk) < length($key);
            push @sample, sprintf("%s => %s", $key_chunk, $val_chunk);
        }
        $sample_text = sprintf("{%s%s} (%d keys)",
            join(', ', @sample),
            $key_count > $sample_count ? ' ...' : '',
            $key_count,
        );
    } elsif (is_arrayref($subject)) {
        my @sample;
        my $total_len = scalar @$subject;
        $sample_count = $total_len > $sample_count ? $sample_count : $total_len;
        for (my $i = 0; $i < $sample_count; $i++) {
            my $val = $subject->[$i];
            my $val_chunk;
            if (ref $val) {
                $val_chunk = ref $val;
            } elsif (!defined $val) {
                $val_chunk = '(undef)';
            } else {
                $val_chunk = substr($val, 0, $scalar_sample_size);
                $val_chunk .= '...' if length($val_chunk) < length($val);
            }
            push @sample, $val_chunk;
        }
        $sample_text = sprintf("[%s%s] (len %d)",
            join(', ', @sample),
            $total_len > $sample_count ? ' ...' : '',
            $total_len,
        );
    } elsif (is_coderef($subject)) {
        my $info = sub_info($subject);
        $sample_text = sprintf("sub %s { ... } (L%d-%d in %s (%s))",
            $info->{name},
            $info->{start_line},
            $info->{end_line},
            $info->{package},
            $info->{file},
        );
    }

    return "$ref: $sample_text";
}

1;

=head1 NAME

Devel::Optic - Production safe variable inspector

=head1 SYNOPSIS

  use Devel::Optic;
  my $optic = Devel::Optic->new();
  my $foo = { bar => ['baz', 'blorg', { clang => 'pop' }] };

  # 'HASH: {bar => ARRAY} (1 keys)"
  $optic->inspect('$foo');

  # 'ARRAY: [baz, blorg, HASH] (len 3)'
  $optic->inspect(q|$foo->{'bar'}|);

  # 'pop (len 3)'
  $optic->inspect(q|$foo->{'bar'}->[-1]->{'clang'}|);

=head1 DESCRIPTION

L<Devel::Optic> is a L<fiberscope|https://en.wikipedia.org/wiki/Fiberscope> for
Perl programs. Just like a real fiberscope, it provides 'nondestructive
inspection' of your variables. In other words: use this in your production
environment to figure out what the heck is in your variables, without worrying
whether the reporting code will blow up your program by trying shove gigabytes
into the logging pipeline.

It provides a basic Perl-ish syntax (a 'query') for extracting bits
of complex data structures from a Perl scope based on the variable name. This
is intended for use by debuggers or similar introspection/observability tools
where the consuming audience is a human troubleshooting a system.

Devel::Optic will summarize the selected data structure into a short,
human-readable message. No attempt is made to make the summary contents
machine-readable: it should be immediately passed to a logging pipeline or
other debugging tool.

=head1 METHODS

=head2 new

  my $o = Devel::Optic->new(%options);

C<%options> may be empty, or contain any of the following keys:

=over 4

=item C<uplevel>

Which Perl scope to view. Default: 1 (scope that C<Devel::Optic> is called from)

=item C<scalar_truncation_size>

Size, in C<substr> length terms, that scalar values are truncated to for
viewing. Default: 256.

=item C<scalar_sample_size>

Size, in C<substr> length terms, that scalar children of a summarized data
structure are trimmed to for inclusion in the summary. Default: 64.

=item C<sample_count>

Number of keys/indices to display when summarizing a hash or arrayref. Default: 4.

=back

=head2 inspect

  my $stuff = { foo => ['a', 'b', 'c'] };
  my $o = Devel::Optic->new;
  # 'a (len 1)'
  $o->inspect(q|$stuff->{'foo'}->[0]|);

This is the primary method. Given a query, it will return a summary of the data
structure found at that path.

=head2 fit_to_view

    my $some_variable = ['a', 'b', { foo => 'bar' }, [ 'blorg' ] ];

    my $o = Devel::Optic->new();
    # "ARRAY: [ 'a', 'b', HASH, ARRAY ]"
    $o->fit_to_view($some_variable);

This method takes a Perl object/data structure and produces a 'squished'
summary of that object/data structure. This summary makes no attempt to be
comprehensive: its goal is to maximally aid human troubleshooting efforts,
including efforts to refine a previous invocation of Devel::Optic with a more
specific query.

=head2 full_picture

This method takes a 'query' and uses it to extract a data structure from the
L<Devel::Optic>'s C<uplevel>. If the query points to a variable that does not
exist, L<Devel::Optic> will croak.

=head3 QUERY SYNTAX

L<Devel::Optic> uses a Perl-ish data access syntax for queries.

A query always starts with a variable name in the scope being picked, and
uses C<-E<gt>> to indicate deeper access to that variable. At each level, the
value should be a key or index that can be used to navigate deeper or identify
the target data.

For example, a query like this:

    %my_cool_hash->{'a'}->[1]->{'needle'}

Applied to a scope like this:

    my %my_cool_hash = (
        a => ["blub", { needle => "find me!", some_other_key => "blorb" }],
        b => "frobnicate"
    );

Will return the value:

    "find me!"

A less specific query on the same data structure:

    %my_cool_hash->{'a'}

Will return that branch of the tree:

    ["blub", { needle => "find me!", some_other_key => "blorb" }]

Other syntactic examples:

    $hash_ref->{'a'}->[0]->[3]->{'blorg'}
    @array->[0]->{'foo'}
    $array_ref->[0]->{'foo'}
    $scalar

=head4 QUERY SYNTAX ALTNERATIVES

The query syntax attempts to provide a reasonable amount of power
for navigating Perl data structures without risking the stability of the system
under inspection.

In other words, while C<eval '$my_cool_hash{a}-E<gt>[1]-E<gt>{needle}'> would
be a much more powerful solution to the problem of navigating Perl data
structures, it opens up all the cans of worms at once.

The current syntax might be a little bit "uncanny valley" in that it looks like
Perl, but is not Perl. It is Perl-ish. It also might be too complex, since it
allows fancy things like nested resolution:

    $foo->{$bar}

Or even:

    %my_hash->{$some_arrayref->[$some_scalar->{'key'}]}->{'needle'}

Ouch. In practice I hope and expect that the majority of queries will be
simple scalars, or maybe one or two chained hashkey/array index lookups.

I'm open to exploring other syntax in this area as long as it is aligned with
the following goals:

=over 4

=item Simple query model

As a debugging tool, you have enough on your brain just debugging your system.
Second-guessing your query syntax when you get unexpected results is a major
distraction and leads to loss of trust in the tool (I'm looking at you,
ElasticSearch).

=item O(1), not O(n) (or worse)

I'd like to avoid globs or matching syntax that might end up iterating over
unbounded chunks of a data structure. Traversing a small, fixed number of keys
in 'parallel' sounds like a sane extension, but anything which requires
iterating over the entire set of hash keys or array indicies is likely to
surprise when debugging systems with unexpectedly large data structures.

=back

=head1 SEE ALSO

=over 4

=item *

L<PadWalker>

=item *

L<Devel::Probe>

=back
