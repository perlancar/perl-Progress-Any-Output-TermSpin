package Progress::Any::Output::TermSpin;

# DATE
# VERSION

use 5.010001;
use strict;
use utf8;
use warnings;

#use Color::ANSI::Util qw(ansifg ansibg);
#use Text::ANSI::Util qw(ta_mbtrunc ta_mbswidth ta_length);
use Time::HiRes qw(time);
#require Win32::Console::ANSI if $^O =~ /Win/;

$|++;

our %STYLES = (
    line     => {utf8=>0, chars=>'|/-\\'},
    bubble   => {utf8=>0, chars=>'.oOo'},
    pie_utf8 => {utf8=>1, chars=>'○◔◑◕●'},
);

# patch handles
my ($ph1, $ph2, $ph3);

my $laa_obj;
my $has_printed_log;

sub _patch {
    my $out = shift;

    return if $ph1;
    require Monkey::Patch::Action;
    $ph1 = Monkey::Patch::Action::patch_package(
        'Log::Any::Adapter::ScreenColoredLevel', 'hook_after_log', 'replace',
        sub {
            my $self = shift;
            undef $out->{_lastlen};

            # don't print newline after each log, do it before instead. so we
            # can print spinning cursor

            $laa_obj = $self;
            $has_printed_log++;
        }
    ) if defined &{"Log::Any::Adapter::ScreenColoredLevel::hook_after_log"};

    $ph2 = Monkey::Patch::Action::patch_package(
        'Log::Any::Adapter::ScreenColoredLevel', 'hook_before_log', 'replace',
        sub {
            my $self = shift;

            # clean spinning cursor, if exists
            $out->cleanup;

            # print newline before log (see above comment)
            return unless $has_printed_log;
            print { $self->{_fh} } "\n";

            $out->keep_delay_showing if $out->{show_delay};
        }
    ) if defined &{"Log::Any::Adapter::ScreenColoredLevel::hook_before_log"};

    $ph3 = Monkey::Patch::Action::patch_package(
        'Log::Any::Adapter::ScreenColoredLevel', 'DESTROY', 'add_or_replace',
        sub {
            my $self = shift;

            return unless $has_printed_log;
            print { $self->{_fh} } "\n";
        }
    );
}

sub _unpatch {
    undef $ph1;
    undef $ph2;
    undef $ph3;
}

sub new {
    my ($class, %args0) = @_;

    my %args;

    $args{style} = delete($args0{style}) // 'line';
    $STYLES{$args{style}} or die "Unknown style '$args{style}'";

    $args{fh} = delete($args0{fh}) // \*STDOUT;

    $args{speed} = delete($args0{speed}) // 0.2;

    $args{show_delay} = delete($args0{show_delay});

    keys(%args0) and die "Unknown output parameter(s): ".
        join(", ", keys(%args0));

    $args{_last_hide_time} = time();

    my $self = bless \%args, $class;
    $self->_patch;

    # XXX hackish
    $Progress::Any::output_data{"$self"}{freq} = -$args{speed};

    $self;
}

sub update {
    my ($self, %args) = @_;

    my $now = time();

    # if there is show_delay, don't display until we've surpassed it
    if (defined $self->{show_delay}) {
        return if $now - $self->{show_delay} < $self->{_last_hide_time};
    }

    # "erase" previous display
    my $ll = $self->{_lastlen};
    if (defined $self->{_lastlen}) {
        print { $self->{fh} } "\b" x $self->{_lastlen};
        undef $self->{_lastlen};
    }

    my $chars = $STYLES{$self->{style}}{chars};
    if (!defined($self->{_char_index})) {
        $self->{_char_index} = 0;
        $self->{_last_change_char_time} = $now;
    } else {
        if (($now - $self->{_last_change_char_time}) > $self->{speed}) {
            $self->{_last_change_char_time} = $now;
            $self->{_char_index}++;
            $self->{_char_index} = 0 if $self->{_char_index} >= length($chars);
        }
    }
    my $char = substr($chars, $self->{_char_index}, 1);
    print { $self->{fh} } " ", $char;

    $self->{_lastlen} = 2;
}

sub cleanup {
    my ($self) = @_;

    # sometimes (e.g. when a subtask's target is undefined) we don't get
    # state=finished at the end. but we need to cleanup anyway at the end of
    # app, so this method is provided and will be called by e.g.
    # Perinci::CmdLine

    my $ll = $self->{_lastlen};
    return unless $ll;
    print { $self->{fh} } "\b" x $ll, " " x $ll, "\b" x $ll;
}

sub keep_delay_showing {
    my $self = shift;

    $self->{_last_hide_time} = time();
}

sub DESTROY {
    my $self = shift;
    $self->_unpatch;

    return unless $has_printed_log;
    print { $laa_obj->{_fh} // \*STDOUT } "\n";
    undef $laa_obj;
}

1;
# ABSTRACT: Output progress to terminal as spinning cursor

=for Pod::Coverage ^(update|cleanup)$

=head1 SYNOPSIS

 use Progress::Any::Output;

 # use default options
 Progress::Any::Output->set('TermSpin');

 # set options
 Progress::Any::Output->set('TermSpin',
                            style=>"bubble", fh=>\*STDOUT, speed=>0.2, show_delay=>5);


=head1 DESCRIPTION


=head1 METHODS

=head2 new(%args) => obj

Instantiate. Usually called through C<< Progress::Any::Output->set("TermSpin",
%args) >>.

Known arguments:

=over

=item * style => str (default: 'line')

Available styles:

# CODE: require Progress::Any::Output::TermSpin; my $styles = \%Progress::Any::Output::TermSpin::STYLES; print "=over\n\n"; for my $style (sort keys %$styles) { print "=item * $style\n\n$styles->{$style}{chars}.\n\n" } print "=back\n\n";

=item * fh => handle (default: \*STDOUT)

Instead of the default STDOUT, you can direct the output to another filehandle.

=item * speed => float (default: 0.2)

=item * show_delay => int

If set, will delay showing the spinning cursor until the specified number of
seconds. This can be used to create, e.g. a CLI application that is relatively
not chatty but will display progress after several seconds of seeming
inactivity.

=back

=head2 keep_delay_showing()

Can be called to reset the timer that counts down to show spinning cursor when
C<show_delay> is defined. For example, if C<show_delay> is 5 seconds and two
seconds have passed, it should've been 3 seconds before spinning cursor is shown
in the next C<update()>. However, if you call this method, it will be 5 seconds
again before showing.


=head1 ENVIRONMENT


=head1 SEE ALSO

L<Progress::Any>

=cut
