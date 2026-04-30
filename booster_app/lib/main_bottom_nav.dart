import 'package:flutter/material.dart';

enum MainTab {
  home,
  request,
  provider,
  orders,
  profile,
}

class MainBottomNavBar extends StatelessWidget {
  const MainBottomNavBar({
    required this.currentTab,
    required this.onTabSelected,
    super.key,
  });

  final MainTab currentTab;
  final ValueChanged<MainTab> onTabSelected;

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: MainTab.values.indexOf(currentTab),
      type: BottomNavigationBarType.fixed,
      selectedItemColor: const Color(0xFF5500FF),
      unselectedItemColor: const Color(0xFFAAAAAA),
      backgroundColor: Colors.white,
      onTap: (index) => onTabSelected(MainTab.values[index]),
      items: const [
        BottomNavigationBarItem(
          icon: Icon(Icons.home_outlined),
          activeIcon: Icon(Icons.home),
          label: 'Home',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.car_repair_outlined),
          activeIcon: Icon(Icons.car_repair),
          label: 'Request',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.tune_outlined),
          activeIcon: Icon(Icons.tune),
          label: 'Offer',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.radar_outlined),
          activeIcon: Icon(Icons.radar),
          label: 'Orders',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.person_outline),
          activeIcon: Icon(Icons.person),
          label: 'Profile',
        ),
      ],
    );
  }
}