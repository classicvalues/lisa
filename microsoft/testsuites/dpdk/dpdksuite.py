# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

from pathlib import PurePath

from assertpy import assert_that

from lisa import Node, TestCaseMetadata, TestSuite, TestSuiteMetadata
from lisa.features import Sriov
from lisa.testsuite import simple_requirement
from lisa.operating_system import Ubuntu, Redhat, CentOs, Oracle
from lisa.tools import Git
from typing import List, Dict
import re


@TestSuiteMetadata(
    area="dpdk",
    category="functional",
    description="""
    This test suite check DPDK functionality
    """,
)
class dpdk(TestSuite):
    @TestCaseMetadata(
        description="""
            This test case checks DPDK can be built and installed correctly.
        """,
        requirement=simple_requirement(
            supported_features=[Sriov],
        ),
        priority=1,
    )
    def check_dpdk_build(self, case_name: str, node: Node) -> None:
        sriov_feature = node.features[Sriov]
        sriov_is_enabled = sriov_feature.enabled()
        self.log.info(f"Verify SRIOV is enabled: {sriov_is_enabled}")
        assert_that(sriov_is_enabled).described_as(
            "SRIOV was not enabled for this test node."
        )
        # self._install_dpdk_dependencies(node)
        self._hugepages_init(node)
        self._hugepages_enable(node)
        # self._install_dpdk(node)
        # self._execute_expect_zero(node, "/usr/local/bin/dpdk-testpmd --version")
        nics = self._get_nic_names(node)
        pairings = self._get_primary_secondary_pairings(node, nics)

    _ubuntu_packages = [
        "librdmacm-dev",
        "librdmacm1",
        "build-essential",
        "libnuma-dev",
        "libmnl-dev",
        "libelf-dev",
        "meson",
        "rdma-core",
        "librdmacm-dev",
        "librdmacm1",
        "build-essential",
        "libnuma-dev",
        "libmnl-dev",
        "libelf-dev",
        "dpkg-dev",
        "pkg-config",
        "python3-pip",
        "python3-pyelftools",
        "python-pyelftools",
    ]
    _redhat_packages = [
        "gcc",
        "make",
        "git",
        "tar",
        "wget",
        "dos2unix",
        "psmisc",
        "kernel-devel",
        "numactl-devel.x86_64",
        "librdmacm-devel",
        "pkgconfig",
        "libmnl-devel",
        "elfutils-libelf-devel",
        "python3-pip",
    ]
    _rte_target = "x86_64-native-linuxapp-gcc"
    _dpdk_github = "https://github.com/DPDK/dpdk.git"
    _ninja_url = (
        "https://github.com/ninja-build/ninja/releases/download/v1.10.2/ninja-linux.zip"
    )

    _nic_attributes_regex = r"([a-zA-Z_]+),?"

    def _install_dpdk_dependencies(self, node: Node) -> None:
        if isinstance(node.os, Ubuntu):
            for package in self._ubuntu_packages:
                node.os.install_packages(package)
            self.log.info("Packages installed for Ubunutu")
            self._execute_expect_zero(node, "pip3 install --upgrade meson")
            self._execute_expect_zero(node, "mv /usr/bin/meson /usr/bin/meson.bak")
            self._execute_expect_zero(node, "ln -s /usr/local/bin/meson /usr/bin/meson")
            self._execute_expect_zero(node, "pip3 install --upgrade ninja")

        elif isinstance(node.os, Redhat) or isinstance(node.os, CentOs):
            self._execute_expect_zero(
                node, "yum update -y --disablerepo='*' --enablerepo='*microsoft*'"
            )
            node.os.install_packages(
                ["groupinstall", "'Infiniband Support'"], signed=False
            )  # todo gross hack to support groupinstall
            for package in self._redhat_packages:
                node.os.install_packages(package)
            result = node.execute(
                "dracut --add-drivers 'mlx4_en mlx4_ib mlx5_ib' -f"
            )  # add mellanox drivers
            self.log.debug("\n".join([result.stdout, result.stderr]))
            self._execute_expect_zero(node, "systemctl enable rdma")
            self._execute_expect_zero(node, "pip3 install --upgrade meson")
            self._execute_expect_zero(node, "ln -s /usr/local/bin/meson /usr/bin/meson")

            self._execute_expect_zero(
                node,
                f"wget {self._ninja_url}",
            )
            self._execute_expect_zero(
                node, "unzip ninja-linux.zip && mv ninja /usr/bin/ninja"
            )
            self._execute_expect_zero(node, "pip3 install --upgrade pyelftools")

    def _execute_expect_zero_with_path(
        self, node: Node, cmd: str, path: PurePath
    ) -> str:
        result = node.execute(cmd, sudo=True, cwd=path, shell=True)
        result.assert_exit_code()
        self.log.info(result.stdout)  # TODO: debug

        return result.stdout

    def _execute_expect_zero(self, node: Node, cmd: str) -> str:
        return self._execute_expect_zero_with_path(node, cmd, node.working_path)

    def _hugepages_init(self, node: Node) -> None:
        self._execute_expect_zero(node, "mkdir -p /mnt/huge")
        self._execute_expect_zero(node, "mkdir -p /mnt/huge-1G")
        self._execute_expect_zero(node, "mount -t hugetlbfs nodev /mnt/huge")
        self._execute_expect_zero(
            node, "mount -t hugetlbfs nodev /mnt/huge-1G -o 'pagesize=1G'"
        )

    def _hugepages_enable(self, node: Node) -> None:
        self._execute_expect_zero(
            node,
            "echo 4096 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages",
        )
        self._execute_expect_zero(
            node,
            "echo 1 > /sys/devices/system/node/node0/hugepages/hugepages-1048576kB/nr_hugepages",
        )
        result = node.execute("grep -i huge /proc/meminfo && ls /mnt/", shell=True)
        self.log.info(f"hugepages status \n{result.stdout}")

    def _install_dpdk(self, node: Node) -> None:
        git_tool = node.tools[Git]
        git_tool.clone(self._dpdk_github, cwd=node.working_path)
        dpdk_path = node.working_path.joinpath("dpdk")
        self._execute_expect_zero_with_path(node, "meson build", dpdk_path)
        self.log.info(node.execute("ls -la", cwd=dpdk_path).stdout)
        dpdk_build_path = dpdk_path.joinpath("build")
        self._execute_expect_zero_with_path(node, "which ninja", dpdk_build_path)
        self._execute_expect_zero_with_path(node, "ninja", dpdk_build_path)
        self._execute_expect_zero_with_path(node, "ninja install", dpdk_build_path)
        self._execute_expect_zero_with_path(node, "ldconfig", dpdk_build_path)

    def _get_nic_names(self, node: Node) -> List[str]:
        result = node.execute(
            " ls /sys/class/net/ | grep -Ev $(ls /sys/devices/virtual/net)",
            shell=True,
            sudo=True,
        )
        nic_names = result.stdout.split("\r\n")
        for item in nic_names:
            assert_that(item).is_not_equal_to("").described_as(
                "nic name could not be found"
            )
        self.log.info(f"network devices: {nic_names}")
        return nic_names

    def _get_nic_device(self, node: Node, nic_name: str) -> str:
        nic_device = self._execute_expect_zero(
            node, f"readlink /sys/class/net/{nic_name}/device"
        )
        base_device_name = self._execute_expect_zero(node, f"basename {nic_device}")
        assert_that(base_device_name).is_not_equal_to("")
        return base_device_name

    def _get_primary_secondary_pairings(
        self, node: Node, nic_list: List[str]
    ) -> Dict[str, str]:
        master_nics = dict()
        result = node.execute(
            "echo 'export PATH=$PATH:/usr/sbin' >> ~/.bashrc", shell=True
        )
        self.log.info(result.stdout)
        result = node.execute("echo $PATH", shell=True)
        self.log.info(result.stdout)

        for nic in nic_list:
            ip_addr_output = self._execute_expect_zero(node, f"ip addr show {nic}")
            attributes_search = re.search(self._nic_attributes_regex, ip_addr_output)
            self.log.info(attributes_search.groups())
            if attributes_search and "SLAVE" in attributes_search.groups():
                # this following search doesn't seem to be portable for REDHAT
                for master_nic in nic_list:
                    if f"master {master_nic}" in ip_addr_output:
                        assert_that(master_nic).is_not_equal_to(nic).described_as(
                            "Slave NIC was found paired to itself, something went wrong."
                        )
                        master_nics[master_nic] = nic
                        break
        self.log.info(f"found primary->secondary nic pairings:\n{master_nics}")
        return master_nics