# Copyright 2014 Canonical Ltd.  This software is licensed under the
# GNU Affero General Public License version 3 (see the file LICENSE).

"""Disk erasing userdata generation."""

from __future__ import (
    absolute_import,
    print_function,
    unicode_literals,
    )

str = None

__metaclass__ = type
__all__ = [
    "generate_user_data",
]

from metadataserver.user_data.snippets import get_userdata_template_dir
from metadataserver.user_data.utils import (
    generate_user_data as _generate_user_data,
    )


def generate_user_data(node):
    """Produce the disk erase script.

    :rtype: `bytes`
    """
    userdata_dir = get_userdata_template_dir()
    result = _generate_user_data(
        node, userdata_dir, 'user_data_disk_erasing.template',
        'user_data_config.template')
    return result
