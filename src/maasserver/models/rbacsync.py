# Copyright 2018 Canonical Ltd.  This software is licensed under the
# GNU Affero General Public License version 3 (see the file LICENSE).

"""RBACSync objects."""

__all__ = [
    "RBACSync",
]

from django.db.models import (
    Manager,
    Model,
)
from django.db.models.fields import (
    CharField,
    DateTimeField,
    IntegerField,
)
from maasserver import DefaultMeta


class RBAC_ACTION:
    #: Perform a full sync.
    FULL = 'full'
    #: Add a new resource.
    ADD = 'add'
    #: Update a resource.
    UPDATE = 'update'
    #: Remove a resource.
    REMOVE = 'remove'


RBAC_ACTION_CHOICES = [
    (RBAC_ACTION.FULL, 'full'),
    (RBAC_ACTION.ADD, 'add'),
    (RBAC_ACTION.UPDATE, 'update'),
    (RBAC_ACTION.REMOVE, 'remove'),
]


class RBACSyncManager(Manager):
    """Manager for `RBACSync` records."""

    def changes(self):
        """Returns the changes that have occurred."""
        return list(self.order_by('id'))

    def clear(self):
        """Deletes all `RBACSync`."""
        self.all().delete()


class RBACSync(Model):
    """A row in this table denotes a change that requires information RBAC
    micro-service to be updated.

    Typically this will be populated by a trigger within the database. A
    listeners in regiond will be notified and consult the un-synced records
    in this table. This way we can consistently publish RBAC information to the
    RBAC service in an HA environment.
    """

    class Meta(DefaultMeta):
        """Default meta."""

    objects = RBACSyncManager()

    action = CharField(
        editable=False, max_length=6, null=False, blank=True,
        choices=RBAC_ACTION_CHOICES, default=RBAC_ACTION.FULL,
        help_text="Action that should occur on the RBAC service.")

    # An '' string is used when action is 'full'.
    resource_type = CharField(
        editable=False, max_length=255, null=False, blank=True,
        help_text="Resource type that as been added/updated/removed.")

    # A `None` is used when action is 'full'.
    resource_id = IntegerField(
        editable=False, null=True, blank=True,
        help_text="Resource ID that has been added/updated/removed.")

    # A '' string is used when action is 'full'.
    resource_name = CharField(
        editable=False, max_length=255, null=False, blank=True,
        help_text="Resource name that has been added/updated/removed.")

    # This field is informational.
    created = DateTimeField(
        editable=False, null=False, auto_now=False, auto_now_add=True)

    # This field is informational.
    source = CharField(
        editable=False, max_length=255, null=False, blank=True,
        help_text="A brief explanation what changed.")
