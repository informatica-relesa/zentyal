# Copyright (C) 2008-2012 eBox Technologies S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

# Class: EBox::Model::Component
#
#   This class is intended to provide common methods which are used
#   by <EBox::Model::Composite> and <EBox::Model::DataTable>.
#

package EBox::Model::Component;

use strict;
use warnings;

use EBox::Global;
use EBox::Gettext;
use EBox::Exceptions::InvalidType;
use EBox::Exceptions::MissingArgument;

use Encode;
use Error qw(:try);
use POSIX qw(getuid);

# Method: parentModule
#
#        Get the parent confmodule for the model
#
# Returns:
#
#        <EBox::Module::Config> - the module
#
sub parentModule
{
    my ($self) = @_;

    return $self->{'confmodule'};
}


# Method: global
#
# returns a EBox::Global instance with the correct read-only status
#
sub global
{
    my ($self) = @_;

    return $self->{'confmodule'}->global();
}

# Method: modelGetter
#
# return a sub which is a getter of the specified model from the specified
# module. Useful for foreignModel attribute
#
#  Parameters:
#    module
#    model
sub modelGetter
{
    my ($self, $module, $model) = @_;
    my $global = $self->global();
    return sub{
        return $global->modInstance($module)->model($model);
    };
}



# Method: pageTitle
#
#   This method must be overriden by the component to show a page title
#
# Return:
#
#   string or undef
#
sub pageTitle
{
    my ($self) = @_;

    return undef;
}

# Method: headTitle
#
#   This method must be overriden by the component to show a headTitle
#
# Return:
#
#   string or undef
#
sub headTitle
{
    my ($self) = @_;

    return undef;
}

# Method: help
#
#     Get the help message from the model
#
# Returns:
#
#     string - containing the i18n help message
#
sub help
{
    return '';
}

# Method: keywords
#
#   Returns words related to the model, extracted from different sources such
#   as row names, help, ..., that can be used to make lookups from words to
#   models, menus, ...
#
# Return:
#
#   string array - the keywords
#
sub keywords
{
    my ($self) = @_;

    my $help = $self->help();
    Encode::_utf8_on($help);
    return [split('\W+', lc($help))];
}

# Method: parent
#
#   Return component's parent.
#   If the component is child of a composite the parent is the top's composite parent
#
# Returns:
#
#   An instance of a class implementing <EBox::Model::DataTable> or <EBox::Model::Composite>
#
sub parent
{
    my ($self) = @_;

    return $self->{'parent'};
}

# Method: parentRow
#
#    Is the component is a submodel of a DataTable return the row where the
#    parent model resides
#
# Returns:
#
#       row object or undef if there is not
#
sub parentRow
{
    my ($self) = @_;

    unless ($self->{parent}) {
        return undef;
    }

    my $dir = $self->directory();
    my @parts = split ('/', $dir);

    my $rowId = undef;
    for (my $i = scalar (@parts) - 1; $i > 0; $i--) {
        if (($parts[$i] eq 'form') or ($parts[$i - 1] eq 'keys')) {
            $rowId = $parts[$i];
            last;
        }
    }

    my $row = $self->{parent}->row($rowId);
    unless ($row) {
        throw EBox::Exceptions::Internal("Cannot find row with rowId $rowId. Component directory: $dir.");
    }

    return $row;
}


# Method: menuFolder
#
#   Override this function if you model is placed within a folder
#   from other module
#
sub menuFolder
{
    return undef;
}

# Method: disabledModuleWarning
#
#       Return the warn message to inform if the parent module is disabled
#
# Returns:
#
#       String - The warn message if the module is disabled
#
#       Empty string - if module is enabled
#
sub disabledModuleWarning
{
    my ($self) = @_;

    # Avoid to show warning if running in usercorner's apache
    return '' unless (getuid() == getpwnam(EBox::Config::user()));

    my $pageTitle = $self->pageTitle();

    if ($self->isa('EBox::Model::DataTable')) {
        my $htmlTitle = @{$self->viewCustomizer()->HTMLTitle()};
        # Do not show warning on nested components
        return '' unless ($pageTitle or $htmlTitle);
    } elsif ($self->isa('EBox::Model::Composite')) {
        return '' unless ($pageTitle);
    } else {
        return '';
    }

    my $module = $self->parentModule();;
    unless (defined ($module) and $module->isa('EBox::Module::Service')) {
        return '';
    }

    if ($module->isEnabled()) {
        return '';
    } else {
        # TODO: If someday we implement the auto-enable for dependencies with one single click
        # we could replace the Module Status link with a "Click here to enable it" one
        return __x("{mod} module is disabled. Don't forget to enable it on the {oh}Module Status{ch} section, otherwise your changes won't have any effect.",
                   mod => $module->printableName(), oh => '<a href="/ServiceModule/StatusView">', ch => '</a>');
    }
}

1;
