# Copyright 2023 Canonical Ltd.  This software is licensed under the
# GNU Affero General Public License version 3 (see the file LICENSE).

"""Temporal Worker service."""

import asyncio

from twisted.application.service import Service
from twisted.internet.asyncioreactor import AsyncioSelectorReactor
from twisted.internet.defer import (
    Deferred,
    DeferredList,
    inlineCallbacks,
    returnValue,
)

from maasserver.config import RegionConfiguration
from maasserver.models.user import create_auth_token, get_auth_tokens
from maasserver.service_monitor import service_monitor, SERVICE_STATE
from maasserver.utils.threads import deferToDatabase
from maasserver.worker_user import get_worker_user
from maasserver.workflow.api_activities import MAASAPIActivities
from maasserver.workflow.bootresource import (
    BootResourcesActivities,
    DeleteBootResourceWorkflow,
    DownloadBootResourceWorkflow,
    SyncBootResourcesWorkflow,
)
from maasserver.workflow.commission import CommissionNWorkflow
from maasserver.workflow.configure import ConfigureWorkerPoolWorkflow
from maasserver.workflow.deploy import DeployNWorkflow
from maasserver.workflow.power import PowerNWorkflow
from maasserver.workflow.worker import Worker
from provisioningserver.utils.env import MAAS_ID


class TemporalWorkerService(Service):
    def __init__(self, reactor):
        super().__init__()

        self._workers = []
        if isinstance(reactor, AsyncioSelectorReactor):
            self._loop = asyncio.get_event_loop()
        else:  # handle crochet reactor
            self._loop = asyncio.new_event_loop()

    def get_token(self):
        user = get_worker_user()
        for token in reversed(get_auth_tokens(user)):
            return token
        else:
            return create_auth_token(user)

    def get_maas_url(self) -> str:
        with RegionConfiguration.open() as config:
            base_url = config.maas_url
        return base_url

    @inlineCallbacks
    def startService(self):
        temporal_status = SERVICE_STATE.UNKNOWN
        while temporal_status != SERVICE_STATE.ON:
            status = yield service_monitor.getServiceState(
                "temporal", now=True
            )
            temporal_status = status.active_state

        maas_url = yield deferToDatabase(self.get_maas_url)
        token = yield deferToDatabase(self.get_token)
        maas_id = MAAS_ID.get()

        maas_api_activities = MAASAPIActivities(url=maas_url, token=token)
        boot_res_activities = BootResourcesActivities(
            url=maas_url, token=token, region_id=maas_id
        )

        self._workers = [
            Worker(
                task_queue=f"{maas_id}:region",
                workflows=[
                    DeleteBootResourceWorkflow,
                    DownloadBootResourceWorkflow,
                    SyncBootResourcesWorkflow,
                ],
                activities=[
                    boot_res_activities.delete_bootresourcefile,
                    boot_res_activities.download_bootresourcefile,
                    boot_res_activities.get_bootresourcefile_endpoints,
                    boot_res_activities.get_bootresourcefile_sync_status,
                ],
            ),
            Worker(
                workflows=[
                    CommissionNWorkflow,
                    ConfigureWorkerPoolWorkflow,
                    DeleteBootResourceWorkflow,
                    DeployNWorkflow,
                    DownloadBootResourceWorkflow,
                    PowerNWorkflow,
                    SyncBootResourcesWorkflow,
                ],
                activities=[
                    boot_res_activities.delete_bootresourcefile,
                    boot_res_activities.download_bootresourcefile,
                    boot_res_activities.get_bootresourcefile_sync_status,
                    maas_api_activities.get_rack_controller,
                    maas_api_activities.switch_boot_order,
                ],
            ),
        ]

        defers = [
            Deferred.fromFuture(self._loop.create_task(w.run()))
            for w in self._workers
        ]
        returnValue(DeferredList(defers))

    def stopService(self):
        defers = [
            Deferred.fromFuture(self._loop.create_task(w.stop()))
            for w in self._workers
        ]
        if defers:
            return DeferredList(defers)
